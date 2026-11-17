// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * determinismo guest plumbing: /dev/determinismo.
 *
 *   write(fd, json, n)   one event (JSON object) for the platform: logs, assertions, lifecycle;
 *                        with it, which thread wrote it (its comm and its id) when the page has
 *                        room (its process id: a program's threads one asker, its forked
 *                        processes each their own)
 *   read(fd, buf, n)     n bytes of randomness chosen by the platform (a decision point); the
 *                        platform also learns which thread asks (its comm, the decision's source,
 *                        and its id: an announced label and a request are matched to the next
 *                        pull of the same thread, never another of the same name)
 *   ioctl(fd, DET_IOCTL_WAIT_ACTION, buf)
 *                        sleeps until the platform pushes an action (it raises DET_IRQ at the
 *                        moment it chose), then copies the action into buf and returns its size
 *
 * Each call is one request to the VMM through the doorbell port (a deterministic VM exit).
 * Test authors never use this directly; SDKs and the in-guest runtime do.
 *
 *   ioctl(fd, DET_IOCTL_DURABILITY_ARM, &arm)
 *                        arms (or, with one_in 0, disarms) a node's durability points: its
 *                        cgroup's fsyncs and sync writes. Each is then a decision (a randomness
 *                        pull: seeded, replayed), and one in `one_in` stalls there, or asks for
 *                        the node's crash there (see "Durability points" below)
 *   ioctl(fd, DET_IOCTL_DURABILITY_WAIT, &request)
 *                        sleeps until a durability point asks for its node's crash
 *   ioctl(fd, DET_IOCTL_INTERLEAVE_ARM, &arm)
 *                        arms (or, with one_in 0, disarms) a node's interleavings: one in
 *                        `one_in` of the scheduler's choices among its threads is drawn here
 *                        (see "Interleavings" below)
 *   ioctl(fd, DET_IOCTL_FILE_ERROR_ARM, &arm)
 *                        arms (or, with one_in 0, disarms) a node's file errors: one in `one_in`
 *                        of its reads or writes of its disk's files fails (see "File errors")
 *
 * And detfs (mount -t detfs detfs <dir>): a regular file, `output`, whose writes are those
 * events too. For SDKs that need a regular file (Antithesis's Go SDK truncates its output file,
 * which a device cannot be): truncating it is accepted and changes nothing. And `setup`, which
 * reads 1 once an SDK declared the system's setup complete (the composer waits for it). And
 * `agent`: "idle" while det-agent waits for an action and none is pending (det-init's last wait).
 */
#include <linux/cgroup.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/magic.h>
#include <linux/sched/jobctl.h>
#include <linux/sched/signal.h>
#include <linux/spinlock.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define DET_DOORBELL_PORT 0x510
#define DET_OP_EMIT 1
#define DET_OP_RANDOM 2
#define DET_OP_ACTION 3
#define DET_IRQ 5
#define DET_IOCTL_WAIT_ACTION 0xde01
#define DET_IOCTL_DURABILITY_ARM 0xde02
#define DET_IOCTL_DURABILITY_WAIT 0xde03
#define DET_IOCTL_INTERLEAVE_ARM 0xde04
#define DET_IOCTL_FILE_ERROR_ARM 0xde05
#define DET_MAX_DATA (PAGE_SIZE - 16)

struct det_request {
	u32 op;
	u32 len;
	u64 result;
	u8 data[DET_MAX_DATA];
} __packed;

static struct det_request *req;
/* An SDK declared the system's setup complete (antithesis_setup): detfs's `setup` reads 1. */
static atomic_t det_sdk_setup = ATOMIC_INIT(0);
static DEFINE_MUTEX(det_lock);
static DECLARE_WAIT_QUEUE_HEAD(det_actions);

static void det_call(void);
static atomic_t det_action_pending = ATOMIC_INIT(0);
/*
 * The agent sits in DET_IOCTL_WAIT_ACTION: with no action pending, it is idle (detfs's `agent`).
 * det-init ends a timeline only then: an action pushed as the scenario ended, taken by the agent
 * after det-init had found it not yet busy, never ran (e2e properties: a core extracted at the
 * crash's moment, "the command did not finish").
 */
static atomic_t det_agent_waiting = ATOMIC_INIT(0);
/* It has waited once: before, there is no agent to wait for (none started, or not yet). */
static atomic_t det_agent_seen = ATOMIC_INIT(0);

/* The pending action taken (one taker: the agent), busy first: never idle with one in hand. */
static bool det_action_take(void)
{
	if (!atomic_read(&det_action_pending))
		return false;
	atomic_set(&det_agent_waiting, 0);
	return atomic_xchg(&det_action_pending, 0);
}

static irqreturn_t det_interrupt(int irq, void *context)
{
	atomic_set(&det_action_pending, 1);
	wake_up_interruptible(&det_actions);
	return IRQ_HANDLED;
}

static long det_durability_ioctl(unsigned int cmd, unsigned long arg);
static long det_interleave_ioctl(unsigned long arg);
static long det_file_error_ioctl(unsigned long arg);

static long det_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	long size;

	if (cmd == DET_IOCTL_DURABILITY_ARM || cmd == DET_IOCTL_DURABILITY_WAIT)
		return det_durability_ioctl(cmd, arg);
	if (cmd == DET_IOCTL_INTERLEAVE_ARM)
		return det_interleave_ioctl(arg);
	if (cmd == DET_IOCTL_FILE_ERROR_ARM)
		return det_file_error_ioctl(arg);
	if (cmd != DET_IOCTL_WAIT_ACTION)
		return -ENOTTY;
	atomic_set(&det_agent_seen, 1);
	atomic_set(&det_agent_waiting, 1);
	if (wait_event_interruptible(det_actions, det_action_take())) {
		atomic_set(&det_agent_waiting, 0);
		return -ERESTARTSYS;
	}
	mutex_lock(&det_lock);
	req->op = DET_OP_ACTION;
	req->len = 0;
	det_call();
	size = min_t(u32, READ_ONCE(req->len), DET_MAX_DATA);
	if (copy_to_user((void __user *)arg, req->data, size))
		size = -EFAULT;
	mutex_unlock(&det_lock);
	return size;
}

/*
 * The VMM reads and writes *req during the VM exit this causes. outl() has no memory clobber,
 * so without the barrier the compiler could keep values it stored before the call (or reuse
 * them afterwards) instead of reading what the VMM wrote.
 */
static void det_call(void)
{
	barrier();
	outl((u32)virt_to_phys(req), DET_DOORBELL_PORT);
	barrier();
}

static ssize_t det_write(struct file *f, const char __user *buf, size_t n, loff_t *off)
{
	if (n > DET_MAX_DATA)
		return -EMSGSIZE;
	mutex_lock(&det_lock);
	if (copy_from_user(req->data, buf, n)) {
		mutex_unlock(&det_lock);
		return -EFAULT;
	}
	if (!atomic_read(&det_sdk_setup) && strnstr((char *)req->data, "\"antithesis_setup\"", n))
		atomic_set(&det_sdk_setup, 1);
	req->op = DET_OP_EMIT;
	req->len = n;
	/* The source after the event (its comm, then its thread id), flagged in result, when it fits. */
	req->result = 0;
	if (n + TASK_COMM_LEN + sizeof(u32) <= DET_MAX_DATA) {
		u32 tid = task_tgid_nr(current); /* The process: its threads share labels. */

		memset(req->data + n, 0, TASK_COMM_LEN);
		strscpy((char *)req->data + n, current->comm, TASK_COMM_LEN);
		memcpy(req->data + n + TASK_COMM_LEN, &tid, sizeof(tid));
		req->result = 2;
	}
	det_call();
	mutex_unlock(&det_lock);
	return n;
}

/* A pull's source, in the data the VMM then overwrites with the answer: the asking thread's
 * comm, then its id (flagged in result). */
static void det_source_put(void)
{
	u32 tid = task_tgid_nr(current); /* The process: its threads share labels. */

	memset(req->data, 0, TASK_COMM_LEN);
	strscpy((char *)req->data, current->comm, TASK_COMM_LEN);
	memcpy(req->data + TASK_COMM_LEN, &tid, sizeof(tid));
	req->result = 2;
}

static ssize_t det_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	ssize_t ret;

	n = min_t(size_t, n, DET_MAX_DATA);
	mutex_lock(&det_lock);
	req->op = DET_OP_RANDOM;
	req->len = n;
	/* The source, in the data the VMM then overwrites with the answer. */
	det_source_put();
	det_call();
	ret = copy_to_user(buf, req->data, n) ? -EFAULT : n;
	mutex_unlock(&det_lock);
	return ret;
}

/* Durability points ------------------------------------------------------------------------ */

/*
 * A node's fsyncs, fdatasyncs, msyncs and sync writes all reach vfs_fsync_range: its durability
 * points, where a system persists what it then acts on (a vote, an acknowledged write). The guest
 * kernel calls det_durability_point there (guest/kernel/patches/0008), in the syncing task's
 * context, where it may ask the VMM and sleep: before the file system syncs and once it has.
 * Each sync of an armed node is then a decision (one randomness pull), and the one picked, one in
 * `one_in`:
 *   stall    holds the syncing thread for stall_ms_min to stall_ms_max ms of virtual time, while the
 *            node's other threads run: the interleavings around persisting
 *   crash    parks it before its data reaches the disk (or just after) and asks det-faults
 *            (waiting in DET_IOCTL_DURABILITY_WAIT) for the node's crash: det-faults freezes
 *            the node, disarms it (which releases the parked task, now frozen on its way out:
 *            the freeze left it a pending signal), then cuts its disk and kills it
 * An overlay's sync reaches its upper file's (nested): the file system that holds the data
 * decides, the overlay's own call never, so each sync is one decision.
 */

#define DET_DURABILITY_NODES 32
#define DET_DURABILITY_PARKED 16
#define DET_STALL 0
#define DET_CRASH_BEFORE 1
#define DET_CRASH_AFTER 2

struct det_durability_arm {
	u64 cgroup;		/* The node's cgroup (its directory's inode number in cgroup2). */
	u32 one_in;		/* A pick at one durability point in this many; 0 disarms. */
	u32 mode;		/* DET_STALL, DET_CRASH_BEFORE or DET_CRASH_AFTER. */
	u32 stall_ms_min;	/* A stall lasts from stall_ms_min to stall_ms_max ms. */
	u32 stall_ms_max;
	char node[32];		/* For events. */
} __packed;

struct det_durability_request {
	u64 cgroup;
	s32 pid;
	u32 mode;
	char comm[TASK_COMM_LEN];
} __packed;

struct det_parked {
	struct task_struct *task;
	u64 cgroup;
	bool released;
};

static DEFINE_SPINLOCK(det_durability_lock);
static struct det_durability_arm det_armed[DET_DURABILITY_NODES];
static atomic_t det_armed_count = ATOMIC_INIT(0);
static struct det_parked det_parked[DET_DURABILITY_PARKED];
/* Crash requests, oldest first: parked tasks not yet handed to det-faults. */
static struct det_durability_request det_requests[DET_DURABILITY_PARKED];
static u32 det_request_count;
static DECLARE_WAIT_QUEUE_HEAD(det_durability_requests);
static DECLARE_WAIT_QUEUE_HEAD(det_durability_released);

/* Under det_durability_lock: the armed node of `cgroup`, or NULL. */
static struct det_durability_arm *det_armed_of(u64 cgroup)
{
	int i;

	for (i = 0; i < DET_DURABILITY_NODES; i++)
		if (det_armed[i].one_in && det_armed[i].cgroup == cgroup)
			return &det_armed[i];
	return NULL;
}

/*
 * The arm of the current task's node (one_in 0 when none): its cgroup's, or an ancestor's (a
 * node's processes may sit in cgroups of their own under it, as a container runtime's do).
 */
static struct det_durability_arm det_arm_current(void)
{
	struct det_durability_arm arm = { .one_in = 0 }, *found = NULL;
	struct cgroup *cgroup;
	unsigned long flags;

	spin_lock_irqsave(&det_durability_lock, flags);
	rcu_read_lock();
	for (cgroup = task_dfl_cgroup(current); cgroup && !found; cgroup = cgroup_parent(cgroup))
		found = det_armed_of(cgroup_ino(cgroup));
	rcu_read_unlock();
	if (found)
		arm = *found;
	spin_unlock_irqrestore(&det_durability_lock, flags);
	return arm;
}

/* A randomness pull, as a process's read of /dev/determinismo (its comm is the source). */
static u64 det_pull(void)
{
	u64 value;

	mutex_lock(&det_lock);
	req->op = DET_OP_RANDOM;
	req->len = sizeof(value);
	det_source_put();
	det_call();
	memcpy(&value, req->data, sizeof(value));
	mutex_unlock(&det_lock);
	return value;
}

static void det_emit_stall(const struct det_durability_arm *arm, u32 ms)
{
	char comm[TASK_COMM_LEN];
	int i;

	/* A name is any bytes: none that would end the JSON string. */
	strscpy(comm, current->comm, sizeof(comm));
	for (i = 0; comm[i]; i++)
		if (comm[i] == '"' || comm[i] == '\\' || comm[i] < 0x20)
			comm[i] = '_';
	mutex_lock(&det_lock);
	req->op = DET_OP_EMIT;
	req->len = scnprintf((char *)req->data, DET_MAX_DATA,
			     "{\"event\":\"sync_stalled\",\"details\":{\"node\":\"%.32s\","
			     "\"process\":\"%s\",\"pid\":%d,\"ms\":%u}}",
			     arm->node, comm, task_pid_nr(current), ms);
	req->result = 0;
	det_call();
	mutex_unlock(&det_lock);
}

/*
 * Asks for the node's crash and waits until it is disarmed (the crash's freeze came first, or
 * the fault ended without one). Killable: the freeze does not wake it, the disarm does.
 */
static void det_park(u64 cgroup, u32 mode)
{
	struct det_parked *slot = NULL;
	unsigned long flags;
	bool armed = false;
	int i;

	spin_lock_irqsave(&det_durability_lock, flags);
	/*
	 * Still armed, checked under the disarm's lock: the arm was read as the sync began, and a
	 * fault that ended since (a crash after the sync, its fault over during it) released its
	 * parked tasks already; this one would wait for a release that never comes, the node wedged
	 * at that sync for good (rqlite's leader in run 402: 37 of its 46 progress failures).
	 */
	for (i = 0; i < DET_DURABILITY_NODES && !armed; i++)
		armed = det_armed[i].one_in && det_armed[i].cgroup == cgroup &&
			det_armed[i].mode != DET_STALL;
	for (i = 0; i < DET_DURABILITY_PARKED && armed && !slot; i++) {
		if (!det_parked[i].task)
			slot = &det_parked[i];
	}
	if (slot && det_request_count < DET_DURABILITY_PARKED) {
		struct det_durability_request *request = &det_requests[det_request_count++];

		*slot = (struct det_parked){ .task = current, .cgroup = cgroup };
		request->cgroup = cgroup;
		request->pid = task_pid_nr(current);
		request->mode = mode;
		strscpy(request->comm, current->comm, TASK_COMM_LEN);
	} else {
		slot = NULL;
	}
	spin_unlock_irqrestore(&det_durability_lock, flags);
	if (!slot)
		return; /* Disarmed meanwhile, or no room: no crash here. */
	wake_up_interruptible(&det_durability_requests);
	wait_event_killable(det_durability_released, READ_ONCE(slot->released));
	spin_lock_irqsave(&det_durability_lock, flags);
	slot->task = NULL;
	spin_unlock_irqrestore(&det_durability_lock, flags);
}

extern int (*det_durability_point)(struct file *file, bool after);

/* The kernel's durability point (0008): each mode decides at its own side of the sync. */
static int det_durability(struct file *file, bool after)
{
	struct det_durability_arm arm;
	u64 pull;

	if (!atomic_read(&det_armed_count))
		return 0;
	if (file_inode(file)->i_sb->s_magic == OVERLAYFS_SUPER_MAGIC)
		return 0;
	arm = det_arm_current();
	if (!arm.one_in || after != (arm.mode == DET_CRASH_AFTER))
		return 0;
	pull = det_pull();
	if ((u32)pull % arm.one_in != 0)
		return 0;
	if (arm.mode == DET_STALL) {
		u32 span = arm.stall_ms_max - min(arm.stall_ms_min, arm.stall_ms_max) + 1;
		u32 ms = arm.stall_ms_min + (u32)(pull >> 32) % span;

		det_emit_stall(&arm, ms);
		schedule_timeout_killable(msecs_to_jiffies(ms));
		return 0;
	}
	if (arm.mode == DET_CRASH_AFTER) {
		det_park(arm.cgroup, DET_CRASH_AFTER); /* Synced; frozen before it acts on it. */
		return 0;
	}
	det_park(arm.cgroup, DET_CRASH_BEFORE);
	if (fatal_signal_pending(current))
		return -EIO;
	/*
	 * The crash's freeze: frozen on the way out, then killed, never synced (restarted only if
	 * the crash failed and thawed it). Otherwise it syncs as asked.
	 */
	if (READ_ONCE(current->jobctl) & JOBCTL_TRAP_FREEZE)
		return -ERESTARTNOINTR;
	return 0;
}

static long det_durability_ioctl(unsigned int cmd, unsigned long arg)
{
	struct det_durability_request request;
	struct det_durability_arm arm;
	unsigned long flags;
	int i, free = -1, count = 0;

	if (cmd == DET_IOCTL_DURABILITY_WAIT) {
		if (wait_event_interruptible(det_durability_requests, READ_ONCE(det_request_count)))
			return -ERESTARTSYS;
		spin_lock_irqsave(&det_durability_lock, flags);
		request = det_requests[0];
		for (i = 1; i < det_request_count; i++)
			det_requests[i - 1] = det_requests[i];
		det_request_count--;
		spin_unlock_irqrestore(&det_durability_lock, flags);
		return copy_to_user((void __user *)arg, &request, sizeof(request)) ? -EFAULT : 0;
	}
	if (copy_from_user(&arm, (void __user *)arg, sizeof(arm)))
		return -EFAULT;
	if (arm.mode > DET_CRASH_AFTER)
		return -EINVAL;
	arm.node[sizeof(arm.node) - 1] = 0;
	spin_lock_irqsave(&det_durability_lock, flags);
	for (i = 0; i < DET_DURABILITY_NODES; i++) {
		if (det_armed[i].one_in && det_armed[i].cgroup == arm.cgroup)
			det_armed[i].one_in = 0; /* Replaced (or disarmed). */
		if (!det_armed[i].one_in && free < 0)
			free = i;
	}
	if (arm.one_in && free >= 0)
		det_armed[free] = arm;
	for (i = 0; i < DET_DURABILITY_NODES; i++)
		count += det_armed[i].one_in != 0;
	atomic_set(&det_armed_count, count);
	if (!arm.one_in) {
		/* Disarmed: its parked tasks go on (into the freeze, when a crash comes). */
		for (i = 0; i < DET_DURABILITY_PARKED; i++)
			if (det_parked[i].task && det_parked[i].cgroup == arm.cgroup)
				WRITE_ONCE(det_parked[i].released, true);
		/* And its requests not yet taken are dropped. */
		for (i = 0; i < det_request_count;) {
			if (det_requests[i].cgroup != arm.cgroup) {
				i++;
				continue;
			}
			memmove(&det_requests[i], &det_requests[i + 1],
				(det_request_count - i - 1) * sizeof(det_requests[0]));
			det_request_count--;
		}
	}
	spin_unlock_irqrestore(&det_durability_lock, flags);
	if (!arm.one_in)
		wake_up_all(&det_durability_released);
	return arm.one_in && free < 0 ? -ENOSPC : 0;
}

/* Interleavings --------------------------------------------------------------------------- */

/*
 * The `interleave` fault: while a node is armed, the fair scheduler asks det_interleave_choose
 * at its choices among the node's threads (guest/kernel/patches/0006): which runnable one runs
 * next, whether a woken one runs before its waker goes on, whether a tick preempts the running
 * one. One choice in `one_in` is drawn here (POS-style: random priorities at each scheduling
 * point), the others left to EEVDF. The draws come from a generator seeded from the platform at
 * each arm: replayed with the timeline, and new with each fault, so branches part.
 */

struct det_interleave_arm {
	u64 cgroup;		/* The node's cgroup (its directory's inode number in cgroup2). */
	u32 one_in;		/* A choice drawn at one scheduling point in this many; 0 disarms. */
	u32 reserved;
	char node[32];		/* For events. */
} __packed;

extern int (*det_sched_choose)(struct cgroup *cgroup, unsigned int choices);

static DEFINE_SPINLOCK(det_interleave_lock);
static struct det_interleave_arm det_interleaved[DET_DURABILITY_NODES];
static u64 det_interleave_drawn[DET_DURABILITY_NODES];
static int det_interleaved_count;
static u64 det_interleave_state = 1;

/* xorshift64*: the scheduler's draws between the platform's seeds. */
static u64 det_interleave_next(void)
{
	u64 x = det_interleave_state;

	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	det_interleave_state = x;
	return x * 0x2545f4914f6cdd1dULL;
}

/*
 * Called by the scheduler, its runqueue locked and interrupts off. One vCPU: nothing runs
 * meanwhile, and the ioctl changes the table with interrupts off, so no lock is needed here.
 */
static int det_interleave_choose(struct cgroup *cgroup, unsigned int choices)
{
	u64 draw;
	int i;

	if (!READ_ONCE(det_interleaved_count))
		return -1;
	for (; cgroup; cgroup = cgroup_parent(cgroup)) {
		u64 ino = cgroup_ino(cgroup);

		for (i = 0; i < DET_DURABILITY_NODES; i++) {
			if (!det_interleaved[i].one_in || det_interleaved[i].cgroup != ino)
				continue;
			draw = det_interleave_next();
			if ((u32)draw % det_interleaved[i].one_in)
				return -1;
			det_interleave_drawn[i]++;
			return (draw >> 32) % choices;
		}
	}
	return -1;
}

static void det_emit_interleaved(const char *node, u64 drawn)
{
	mutex_lock(&det_lock);
	req->op = DET_OP_EMIT;
	req->len = scnprintf((char *)req->data, DET_MAX_DATA,
			     "{\"event\":\"interleaved\",\"details\":{\"node\":\"%.32s\","
			     "\"choices\":%llu}}",
			     node, drawn);
	req->result = 0;
	det_call();
	mutex_unlock(&det_lock);
}

static long det_interleave_ioctl(unsigned long arg)
{
	struct det_interleave_arm arm;
	unsigned long flags;
	u64 seed = 0, drawn = 0;
	bool ended = false;
	int i, free = -1, count = 0;

	if (copy_from_user(&arm, (void __user *)arg, sizeof(arm)))
		return -EFAULT;
	arm.node[sizeof(arm.node) - 1] = 0;
	if (arm.one_in)
		seed = det_pull();
	spin_lock_irqsave(&det_interleave_lock, flags);
	for (i = 0; i < DET_DURABILITY_NODES; i++) {
		if (det_interleaved[i].one_in && det_interleaved[i].cgroup == arm.cgroup) {
			det_interleaved[i].one_in = 0; /* Replaced (or disarmed). */
			drawn = det_interleave_drawn[i];
			ended = true;
		}
		if (!det_interleaved[i].one_in && free < 0)
			free = i;
	}
	if (arm.one_in && free >= 0) {
		det_interleaved[free] = arm;
		det_interleave_drawn[free] = 0;
		det_interleave_state = seed | 1; /* Never 0: xorshift's fixed point. */
	}
	for (i = 0; i < DET_DURABILITY_NODES; i++)
		count += det_interleaved[i].one_in != 0;
	WRITE_ONCE(det_interleaved_count, count);
	spin_unlock_irqrestore(&det_interleave_lock, flags);
	/* How many choices it drew, for the fault's end (none: its threads never competed). */
	if (ended && !arm.one_in)
		det_emit_interleaved(arm.node, drawn);
	return arm.one_in && free < 0 ? -ENOSPC : 0;
}

/* File errors ------------------------------------------------------------------------------ */

/*
 * The `file_error` fault: while a node is armed, the guest kernel asks det_file_io at each read
 * and write of a regular file (guest/kernel/patches/0010). Those of the node's own disk (ext4,
 * its writable layer: never the image's erofs, nor procfs) fail one in `one_in` with the armed
 * error before any data moves, as a full disk (ENOSPC, EDQUOT) or a failing one (EIO) returns
 * them. Or, armed for short writes, one buffered write in `one_in` of its disk's files moves
 * only part of what it was asked (guest/kernel/patches/0012), as a filling disk makes it: from an
 * eighth to seven eighths, at least a byte. Counted, not drawn: no exit to the VMM at each read,
 * and the count replays with the timeline.
 */

#define DET_FILE_READS 1
#define DET_FILE_WRITES 2
#define DET_FILE_SHORT 4

struct det_file_error_arm {
	u64 cgroup;		/* The node's cgroup (its directory's inode number in cgroup2). */
	u32 one_in;		/* One call in this many fails; 0 disarms. */
	u32 error;		/* The error returned (positive: EIO, ENOSPC, EDQUOT). */
	u32 calls;		/* DET_FILE_READS, DET_FILE_WRITES, both, or DET_FILE_SHORT. */
	u32 reserved;
	char node[32];		/* For events. */
} __packed;

extern int (*det_file_io)(int read_write, struct file *file);
extern size_t (*det_write_size)(struct file *file, size_t count);

static DEFINE_SPINLOCK(det_file_error_lock);
static struct det_file_error_arm det_file_errors[DET_DURABILITY_NODES];
static u64 det_file_error_calls[DET_DURABILITY_NODES];
static u64 det_file_error_failed[DET_DURABILITY_NODES];
static atomic_t det_file_error_count = ATOMIC_INIT(0);

/* Under det_file_error_lock: the armed node of `cgroup`'s slot, or -1. */
static int det_file_error_slot(u64 cgroup)
{
	int i;

	for (i = 0; i < DET_DURABILITY_NODES; i++)
		if (det_file_errors[i].one_in && det_file_errors[i].cgroup == cgroup)
			return i;
	return -1;
}

/* Under det_file_error_lock: the current task's node's armed slot, or -1. */
static int det_file_error_current(void)
{
	struct cgroup *cgroup;
	int slot = -1;

	rcu_read_lock();
	/* Its cgroup's, or an ancestor's (a container runtime's cgroups under the node's). */
	for (cgroup = task_dfl_cgroup(current); cgroup && slot < 0; cgroup = cgroup_parent(cgroup))
		slot = det_file_error_slot(cgroup_ino(cgroup));
	rcu_read_unlock();
	return slot;
}

static int det_file_error(int read_write, struct file *file)
{
	u32 call = read_write == READ ? DET_FILE_READS : DET_FILE_WRITES;
	unsigned long flags;
	int slot, ret = 0;

	if (!atomic_read(&det_file_error_count))
		return 0;
	if (file_inode(file)->i_sb->s_magic != EXT4_SUPER_MAGIC)
		return 0;
	spin_lock_irqsave(&det_file_error_lock, flags);
	slot = det_file_error_current();
	if (slot >= 0 && (det_file_errors[slot].calls & call) &&
	    ++det_file_error_calls[slot] % det_file_errors[slot].one_in == 0) {
		det_file_error_failed[slot]++;
		ret = -(int)det_file_errors[slot].error;
	}
	spin_unlock_irqrestore(&det_file_error_lock, flags);
	return ret;
}

/* ext4's buffered writes (0012): this one shortened, one in `one_in`, or whole. */
static size_t det_file_write_size(struct file *file, size_t count)
{
	unsigned long flags;
	size_t kept = count;
	u64 calls;
	int slot;

	if (!atomic_read(&det_file_error_count))
		return count;
	spin_lock_irqsave(&det_file_error_lock, flags);
	slot = det_file_error_current();
	if (slot >= 0 && (det_file_errors[slot].calls & DET_FILE_SHORT)) {
		calls = ++det_file_error_calls[slot];
		if (calls % det_file_errors[slot].one_in == 0) {
			det_file_error_failed[slot]++;
			kept = max_t(size_t, 1, count / 8 * (1 + calls % 7));
			kept = min(kept, count - 1);
		}
	}
	spin_unlock_irqrestore(&det_file_error_lock, flags);
	return kept;
}

static void det_emit_file_errors(const char *node, u64 calls, u64 failed)
{
	mutex_lock(&det_lock);
	req->op = DET_OP_EMIT;
	req->len = scnprintf((char *)req->data, DET_MAX_DATA,
			     "{\"event\":\"file_errors\",\"details\":{\"node\":\"%.32s\","
			     "\"calls\":%llu,\"failed\":%llu}}",
			     node, calls, failed);
	req->result = 0;
	det_call();
	mutex_unlock(&det_lock);
}

static long det_file_error_ioctl(unsigned long arg)
{
	struct det_file_error_arm arm;
	unsigned long flags;
	u64 calls = 0, failed = 0;
	bool ended = false;
	int i, free = -1, count = 0;

	if (copy_from_user(&arm, (void __user *)arg, sizeof(arm)))
		return -EFAULT;
	arm.node[sizeof(arm.node) - 1] = 0;
	if (arm.one_in && (!arm.calls || ((arm.calls & (DET_FILE_READS | DET_FILE_WRITES)) &&
					  (!arm.error || arm.error >= MAX_ERRNO))))
		return -EINVAL;
	spin_lock_irqsave(&det_file_error_lock, flags);
	i = det_file_error_slot(arm.cgroup);
	if (i >= 0) {
		det_file_errors[i].one_in = 0; /* Replaced (or disarmed). */
		calls = det_file_error_calls[i];
		failed = det_file_error_failed[i];
		ended = true;
	}
	for (i = 0; i < DET_DURABILITY_NODES && free < 0; i++)
		if (!det_file_errors[i].one_in)
			free = i;
	if (arm.one_in && free >= 0) {
		det_file_errors[free] = arm;
		det_file_error_calls[free] = 0;
		det_file_error_failed[free] = 0;
	}
	for (i = 0; i < DET_DURABILITY_NODES; i++)
		count += det_file_errors[i].one_in != 0;
	atomic_set(&det_file_error_count, count);
	spin_unlock_irqrestore(&det_file_error_lock, flags);
	/* Its calls and how many failed, for the fault's end. */
	if (ended && !arm.one_in)
		det_emit_file_errors(arm.node, calls, failed);
	return arm.one_in && free < 0 ? -ENOSPC : 0;
}

static const struct file_operations det_fops = {
	.owner = THIS_MODULE,
	.read = det_read,
	.write = det_write,
	.unlocked_ioctl = det_ioctl,
};

/* detfs ------------------------------------------------------------------------------------ */

#define DETFS_MAGIC 0x64657466 /* "detf" */

static const struct file_operations det_output_fops = {
	.owner = THIS_MODULE,
	.write = det_write,
	.llseek = noop_llseek,
};

static ssize_t det_setup_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	const char *state = atomic_read(&det_sdk_setup) ? "1\n" : "0\n";

	return simple_read_from_buffer(buf, n, off, state, 2);
}

static const struct file_operations det_setup_fops = {
	.owner = THIS_MODULE,
	.read = det_setup_read,
	.llseek = default_llseek,
};

/* "idle" while the agent waits for an action and none is pending, "busy" otherwise. */
static ssize_t det_agent_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	bool idle = !atomic_read(&det_action_pending) &&
		    (atomic_read(&det_agent_waiting) || !atomic_read(&det_agent_seen));
	const char *state = idle ? "idle\n" : "busy\n";

	return simple_read_from_buffer(buf, n, off, state, 5);
}

static const struct file_operations det_agent_fops = {
	.owner = THIS_MODULE,
	.read = det_agent_read,
	.llseek = default_llseek,
};

static int detfs_fill_super(struct super_block *sb, struct fs_context *fc)
{
	/* Inode numbers from 2 (1 is the root), as simple_fill_super expects. */
	static const struct tree_descr files[] = {
		[2] = { "output", &det_output_fops, 0666 },
		[3] = { "setup", &det_setup_fops, 0444 },
		[4] = { "agent", &det_agent_fops, 0444 },
		{ "" },
	};

	return simple_fill_super(sb, DETFS_MAGIC, files);
}

static int detfs_get_tree(struct fs_context *fc)
{
	return get_tree_single(fc, detfs_fill_super); /* One instance, wherever it is mounted. */
}

static const struct fs_context_operations detfs_context_ops = {
	.get_tree = detfs_get_tree,
};

static int detfs_init_fs_context(struct fs_context *fc)
{
	fc->ops = &detfs_context_ops;
	return 0;
}

static struct file_system_type detfs_type = {
	.owner = THIS_MODULE,
	.name = "detfs",
	.init_fs_context = detfs_init_fs_context,
	.kill_sb = kill_litter_super,
};

static struct miscdevice det_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "determinismo",
	.fops = &det_fops,
	.mode = 0666,
};

static int __init det_init(void)
{
	int err;

	/* Below 4 GiB so the 32-bit doorbell can carry its physical address. */
	req = (struct det_request *)get_zeroed_page(GFP_KERNEL | GFP_DMA32);
	if (!req)
		return -ENOMEM;
	err = request_irq(DET_IRQ, det_interrupt, 0, "determinismo", NULL);
	if (err) {
		free_page((unsigned long)req);
		return err;
	}
	err = misc_register(&det_dev);
	if (err)
		goto irq;
	err = register_filesystem(&detfs_type);
	if (err)
		goto device;
	WRITE_ONCE(det_durability_point, det_durability);
	WRITE_ONCE(det_file_io, det_file_error);
	WRITE_ONCE(det_write_size, det_file_write_size);
	WRITE_ONCE(det_sched_choose, det_interleave_choose);
	return 0;
device:
	misc_deregister(&det_dev);
irq:
	free_irq(DET_IRQ, NULL);
	free_page((unsigned long)req);
	return err;
}

static void __exit det_exit(void)
{
	WRITE_ONCE(det_sched_choose, NULL);
	/* Unloaded only with no node running: no sync is inside det_durability. */
	WRITE_ONCE(det_durability_point, NULL);
	WRITE_ONCE(det_file_io, NULL);
	WRITE_ONCE(det_write_size, NULL);
	synchronize_rcu(); /* The scheduler's calls run with preemption off. */
	unregister_filesystem(&detfs_type);
	misc_deregister(&det_dev);
	free_irq(DET_IRQ, NULL);
	free_page((unsigned long)req);
}

module_init(det_init);
module_exit(det_exit);
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("determinismo guest channel");
