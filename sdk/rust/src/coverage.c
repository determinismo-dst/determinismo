// SPDX-License-Identifier: MIT
// The callbacks of trace-pc-guard instrumentation (the C SDK's, sdk/c/determinismo.h): guards hold
// an edge's number, its top bit set once reported, so each edge costs one event, the first time it
// runs, as the source line it is on when the binary is in the image's /symbols with its debug
// information (as for Antithesis), else as its number; every pass through an edge is a point where
// thread pausing may pause (det_pausing_at). Inside determinismo only; compiled without the
// instrumentation (build.rs). The line lookup and thread pausing are the C SDK's, copied: a
// packaged crate cannot include sdk/c (keep the two the same).
#include <elf.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 02000000
#endif

static int determinismo_coverage_device = -2;

/* An edge's source line: the module holding its call (/proc/self/maps, once per module), its
   GNU build ID (its ELF header in memory), and the table of its lines the host made from the
   image's /symbols when it prepared the image (src/lines.zig's format, as libvoidstar reads it:
   "DETLINES", a count, rows by address {address, line, file offset}, then the file names). */
struct det_lines_row {
  uint64_t address;
  uint32_t line;
  uint32_t file;
};

struct det_native {
  uintptr_t low, high, bias;
  const struct det_lines_row *rows;
  uint64_t count;
  const char *strings;
  size_t strings_size;
};

#define DET_NATIVES_MAX 64
static struct det_native det_natives[DET_NATIVES_MAX];
static int det_native_count;
static int det_natives_lock;

/* The process's maps, read whole (a JVM's run to hundreds of kilobytes). */
static char *det_maps_read(size_t *size) {
  int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  size_t capacity = 1 << 16, used = 0;
  char *text = (char *)malloc(capacity);
  while (text) {
    if (used + 4096 > capacity) {
      char *grown = (char *)realloc(text, capacity * 2);
      if (!grown) { free(text); text = NULL; break; }
      text = grown;
      capacity *= 2;
    }
    ssize_t got = read(fd, text + used, capacity - used - 1);
    if (got <= 0) break;
    used += (size_t)got;
  }
  close(fd);
  if (text) text[used] = 0;
  *size = used;
  return text;
}

/* A maps line: "start-end perms offset device inode   path". */
static int det_maps_line(const char *line, uintptr_t *start, uintptr_t *end, unsigned long *offset,
                         char *path, size_t path_size) {
  unsigned long a, b, c;
  int consumed = 0;
  if (sscanf(line, "%lx-%lx %*s %lx %*s %*s%n", &a, &b, &c, &consumed) < 3) return 0;
  const char *rest = line + consumed;
  while (*rest == ' ') rest++;
  size_t length = 0;
  while (rest[length] && rest[length] != '\n') length++;
  if (length >= path_size) length = path_size - 1;
  memcpy(path, rest, length);
  path[length] = 0;
  *start = a;
  *end = b;
  *offset = c;
  return 1;
}

/* The module holding pc: its range, load bias and key (build ID, or name-<file name>). */
static int det_native_find(uintptr_t pc, struct det_native *found, char *key, size_t key_size) {
  size_t size;
  char *maps = det_maps_read(&size);
  if (!maps) return 0;
  char path[256] = "", each[256];
  uintptr_t start, end, header = 0;
  unsigned long offset;
  found->low = found->high = 0;
  for (char *line = maps; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
    if (!det_maps_line(line, &start, &end, &offset, each, sizeof each)) continue;
    if (pc >= start && pc < end) {
      memcpy(path, each, sizeof path);
      found->low = start;
      found->high = end;
      break;
    }
  }
  if (!found->high) { free(maps); return 0; }
  if (path[0] != '/') { free(maps); key[0] = 0; return 1; } /* Anonymous (JIT) code. */
  for (char *line = maps; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
    if (!det_maps_line(line, &start, &end, &offset, each, sizeof each) || strcmp(each, path) != 0) continue;
    if (start < found->low) found->low = start;
    if (end > found->high) found->high = end;
    if (offset == 0 && !header) header = start;
  }
  free(maps);
  found->bias = 0;
  const char *base = strrchr(path, '/');
  snprintf(key, key_size, "name-%s", base ? base + 1 : path);
  if (!header) return 1;
  const Elf64_Ehdr *elf = (const Elf64_Ehdr *)header;
  if (memcmp(elf->e_ident, ELFMAG, SELFMAG) != 0 || elf->e_ident[EI_CLASS] != ELFCLASS64) return 1;
  const Elf64_Phdr *segments = (const Elf64_Phdr *)(header + elf->e_phoff);
  if (elf->e_type == ET_DYN) { /* Position-independent: where its first segment's page landed. */
    uint64_t lowest = UINT64_MAX;
    for (int i = 0; i < elf->e_phnum; i++)
      if (segments[i].p_type == PT_LOAD && segments[i].p_vaddr < lowest) lowest = segments[i].p_vaddr;
    if (lowest == UINT64_MAX) return 1;
    found->bias = header - (uintptr_t)(lowest & ~(uint64_t)4095);
  }
  for (int i = 0; i < elf->e_phnum; i++) {
    if (segments[i].p_type != PT_NOTE) continue;
    uintptr_t notes_at = found->bias + segments[i].p_vaddr;
    if (notes_at < found->low || notes_at + segments[i].p_filesz > found->high) continue;
    const unsigned char *notes = (const unsigned char *)notes_at;
    size_t at = 0;
    while (at + 12 <= segments[i].p_filesz) {
      uint32_t name_size, description_size, kind;
      memcpy(&name_size, notes + at, 4);
      memcpy(&description_size, notes + at + 4, 4);
      memcpy(&kind, notes + at + 8, 4);
      size_t name_at = at + 12, description_at = name_at + ((name_size + 3) & ~3u);
      if (description_at + description_size > segments[i].p_filesz) break;
      if (kind == NT_GNU_BUILD_ID && name_size == 4 && memcmp(notes + name_at, "GNU", 4) == 0 &&
          description_size * 2 < key_size) {
        for (uint32_t j = 0; j < description_size; j++)
          snprintf(key + 2 * j, 3, "%02x", notes[description_at + j]);
        return 1;
      }
      at = description_at + ((description_size + 3) & ~3u);
    }
  }
  return 1;
}

static void det_lines_load(struct det_native *native, const char *key) {
  char path[160];
  snprintf(path, sizeof path, "/symbols/.determinismo/%s", key);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return;
  off_t size = lseek(fd, 0, SEEK_END);
  if (size < 16) { close(fd); return; }
  const unsigned char *table = (const unsigned char *)mmap(NULL, (size_t)size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (table == MAP_FAILED) return;
  uint64_t count;
  memcpy(&count, table + 8, 8);
  if (memcmp(table, "DETLINES", 8) != 0 || count > ((uint64_t)size - 16) / sizeof(struct det_lines_row)) return;
  native->rows = (const struct det_lines_row *)(table + 16);
  native->count = count;
  native->strings = (const char *)(table + 16 + count * sizeof(struct det_lines_row));
  native->strings_size = (size_t)size - 16 - count * sizeof(struct det_lines_row);
}

/* The module of a code address, found once (a lock held too long, by a thread a fork left
   behind, is not waited for: the edge stays a number). */
static const struct det_native *det_native_at(uintptr_t pc) {
  int count = __atomic_load_n(&det_native_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < count; i++)
    if (pc >= det_natives[i].low && pc < det_natives[i].high) return &det_natives[i];
  for (long spins = 0; __atomic_exchange_n(&det_natives_lock, 1, __ATOMIC_ACQUIRE); spins++)
    if (spins > (1L << 22)) return NULL;
  const struct det_native *result = NULL;
  count = __atomic_load_n(&det_native_count, __ATOMIC_ACQUIRE);
  for (int i = 0; i < count && !result; i++)
    if (pc >= det_natives[i].low && pc < det_natives[i].high) result = &det_natives[i];
  if (!result && count < DET_NATIVES_MAX) {
    struct det_native found = {0};
    char key[96];
    if (det_native_find(pc, &found, key, sizeof key)) {
      det_natives[count] = found;
      if (key[0]) det_lines_load(&det_natives[count], key);
      __atomic_store_n(&det_native_count, count + 1, __ATOMIC_RELEASE);
      result = &det_natives[count];
    }
  }
  __atomic_store_n(&det_natives_lock, 0, __ATOMIC_RELEASE);
  return result;
}

/* "line <file>:<n>" for a code address, or 0 (no table, no line there). */
static int det_line_of(uintptr_t pc, char *out, size_t size) {
  const struct det_native *native = det_native_at(pc);
  if (!native || !native->count || pc <= native->bias) return 0;
  uint64_t address = pc - native->bias - 1; /* The call, not the return address. */
  uint64_t low = 0, high = native->count;
  while (low < high) { /* The last row at or before the address. */
    uint64_t middle = low + (high - low) / 2;
    if (native->rows[middle].address <= address) low = middle + 1; else high = middle;
  }
  if (low == 0) return 0;
  const struct det_lines_row *row = &native->rows[low - 1];
  if (row->line == 0 || row->file >= native->strings_size) return 0;
  const char *file = native->strings + row->file;
  size_t length = 0;
  while (row->file + length < native->strings_size && file[length]) length++;
  int written = snprintf(out, size, "line %.*s:%u", (int)length, file, row->line);
  return written > 0 && (size_t)written < size;
}

/* JSON's escapes for a name in an event. */
static size_t det_json_escaped(char *out, size_t used, size_t size, const char *text) {
  for (; *text && used + 7 < size; text++) {
    unsigned char c = (unsigned char)*text;
    if (c == '"' || c == '\\') {
      out[used++] = '\\';
      out[used++] = (char)c;
    } else if (c < 0x20) {
      used += (size_t)snprintf(out + used, size - used, "\\u%04x", c);
    } else {
      out[used++] = (char)c;
    }
  }
  return used;
}

/* A platform decision: announced by name, then drawn (the C SDK's det_random_below_named). */
static uint64_t det_decision_below(const char *name, uint64_t count) {
  char line[160];
  int length = snprintf(line, sizeof line, "{\"decision\":{\"name\":\"%s\",\"range\":%llu}}", name,
                        (unsigned long long)count);
  if (length > 0) (void)!write(determinismo_coverage_device, line, (size_t)length);
  uint64_t value = 0;
  (void)!read(determinismo_coverage_device, &value, sizeof value);
  return value % count;
}

static uint64_t det_random_u64(void) {
  uint64_t value = 0;
  (void)!read(determinismo_coverage_device, &value, sizeof value);
  return value;
}

/* Thread pausing, the C SDK's: one stretch of two seconds (virtual time) in four, a named
   decision ("thread pausing") at the stretch's first edge, one edge in 64 is a slow point with
   its own pause (1 to 10 ms), drawn for the stretch: a thread reaching one waits there, at most 8
   times a stretch. A thread looks at the clock at its first edge and every 4096. */
#define DET_PAUSING_EDGES_PER_LOOK 4096u
#define DET_PAUSING_PAUSES_MAX 8u
static uint64_t det_pausing_stretch;
static uint64_t det_pausing_seed;
static int det_pausing_lock;
static _Thread_local uint32_t det_pausing_countdown;
static _Thread_local uint64_t det_pausing_thread_stretch;
static _Thread_local uint32_t det_pausing_thread_pauses;

static void det_pausing_at(uint32_t edge) {
  if (det_pausing_countdown == 0) {
    det_pausing_countdown = DET_PAUSING_EDGES_PER_LOOK;
    uint64_t stretch = (uint64_t)time(0) / 2 + 1;
    while (__atomic_test_and_set(&det_pausing_lock, __ATOMIC_ACQUIRE)) {
    }
    if (det_pausing_stretch != stretch) {
      det_pausing_stretch = stretch;
      uint64_t seed = det_decision_below("thread pausing", 4) == 0 ? (det_random_u64() | 1) : 0;
      __atomic_store_n(&det_pausing_seed, seed, __ATOMIC_RELAXED);
    }
    __atomic_clear(&det_pausing_lock, __ATOMIC_RELEASE);
  }
  det_pausing_countdown--;
  uint64_t seed = __atomic_load_n(&det_pausing_seed, __ATOMIC_RELAXED);
  if (!seed) return;
  uint64_t value = (seed ^ edge) * 0x9e3779b97f4a7c15ull; /* The edge's draw for the stretch. */
  value ^= value >> 29;
  value *= 0xbf58476d1ce4e5b9ull;
  value ^= value >> 32;
  if (value % 64 != 0) return;
  uint64_t stretch = __atomic_load_n(&det_pausing_stretch, __ATOMIC_RELAXED);
  if (det_pausing_thread_stretch != stretch) {
    det_pausing_thread_stretch = stretch;
    det_pausing_thread_pauses = 0;
  }
  if (det_pausing_thread_pauses == DET_PAUSING_PAUSES_MAX) return;
  det_pausing_thread_pauses++;
  (void)poll(0, 0, (int)(1 + (value >> 8) % 10)); /* A pause: no file, only the timeout. */
}

#define DET_EDGE_REPORTED 0x80000000u

/* Which edges the timeline reported, shared by every process of every node: the C SDK's
   det_edge_module (a bit per guard in /opt/determinismo/coverage/sdk-<build ID>). */
struct det_edge_module {
  uint32_t *start, *stop;
  unsigned char *bits;
};
#define DET_EDGE_MODULES_MAX 64
static struct det_edge_module det_edge_modules[DET_EDGE_MODULES_MAX];
static int det_edge_module_count;

static unsigned char *det_edges_shared(uintptr_t code, size_t edges) {
  struct det_native module;
  char key[96];
  if (!det_native_find(code, &module, key, sizeof key) || !key[0]) return NULL;
  if (strncmp(key, "name-", 5) == 0) return NULL; /* No build ID: two builds could share it. */
  char path[160];
  snprintf(path, sizeof path, "/opt/determinismo/coverage/sdk-%s", key);
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
  if (fd < 0) return NULL;
  size_t size = ((edges + 7) / 8 + 4095) & ~(size_t)4095;
  unsigned char *bits = NULL;
  if (ftruncate(fd, (off_t)size) == 0) {
    void *address = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (address != MAP_FAILED) bits = (unsigned char *)address;
  }
  close(fd);
  return bits;
}

static int det_edge_reported_before(uint32_t *guard) {
  for (int i = 0; i < det_edge_module_count; i++) {
    struct det_edge_module *module = &det_edge_modules[i];
    if (guard < module->start || guard >= module->stop) continue;
    if (!module->bits) return 0;
    size_t index = (size_t)(guard - module->start);
    unsigned char bit = (unsigned char)(1u << (index % 8));
    return (__atomic_fetch_or(&module->bits[index / 8], bit, __ATOMIC_RELAXED) & bit) != 0;
  }
  return 0;
}

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next = 1;
  if (start == stop || *start) return; /* Already numbered. */
  for (uint32_t *guard = start; guard < stop; guard++) *guard = next++;
  if (determinismo_coverage_device == -2) {
    determinismo_coverage_device = open("/dev/determinismo", O_RDWR | O_CLOEXEC);
  }
  if (det_edge_module_count == DET_EDGE_MODULES_MAX || determinismo_coverage_device < 0) return;
  struct det_edge_module *module = &det_edge_modules[det_edge_module_count];
  module->start = start;
  module->stop = stop;
  module->bits = det_edges_shared((uintptr_t)__builtin_return_address(0), (size_t)(stop - start));
  det_edge_module_count++;
}

/* The node's coverage set, DETERMINISMO_COVERAGE (the Zig SDK's schema.Coverage): source file
   prefixes, those starting with "-" excluded. Whether it holds an edge whose source line is `name`
   ("line <file>:<n>", or NULL when unknown: the binary not in the image's /symbols), the first
   time the edge runs: an edge it leaves out reports nothing and pauses nothing. */
static const char *det_coverage_set(void) {
  static const char *set;
  static int set_read;
  if (!__atomic_load_n(&set_read, __ATOMIC_ACQUIRE)) {
    const char *value = getenv("DETERMINISMO_COVERAGE");
    set = value && *value ? value : 0;
    __atomic_store_n(&set_read, 1, __ATOMIC_RELEASE);
  }
  return set;
}

static int det_coverage_holds(const char *name) {
  const char *set = det_coverage_set();
  if (!set) return 1;
  const char *file = name ? name + 5 : "";
  const char *colon = name ? strrchr(file, ':') : 0;
  size_t length = colon ? (size_t)(colon - file) : strlen(file);
  int included = 1, matched = 0;
  for (const char *entry = set; *entry;) {
    const char *end = strchr(entry, ',');
    size_t size = end ? (size_t)(end - entry) : strlen(entry);
    if (size > 1 && entry[0] == '-') {
      if (size - 1 <= length && memcmp(file, entry + 1, size - 1) == 0) return 0;
    } else if (size > 0 && entry[0] != '-') {
      included = 0;
      if (size <= length && memcmp(file, entry, size) == 0) matched = 1;
    }
    if (!end) break;
    entry = end + 1;
  }
  return included || matched;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  uint32_t edge = *guard;
  if (!edge) return;
  if (determinismo_coverage_device == -2) {
    determinismo_coverage_device = open("/dev/determinismo", O_RDWR | O_CLOEXEC);
  }
  if (determinismo_coverage_device < 0) { /* Outside determinismo: nothing to report or pause. */
    *guard = 0;
    return;
  }
  if (edge & DET_EDGE_REPORTED) {
    det_pausing_at(edge & ~DET_EDGE_REPORTED);
    return;
  }
  char name[448], line[600];
  /* The line, before anything else, only when a set asks for it (a lookup in the line table). */
  int known = -1;
  if (det_coverage_set()) {
    known = det_line_of((uintptr_t)__builtin_return_address(0), name, sizeof name);
    if (!det_coverage_holds(known ? name : 0)) {
      *guard = 0; /* Left out: never again. */
      return;
    }
  }
  *guard = edge | DET_EDGE_REPORTED;
  if (det_edge_reported_before(guard)) {
    det_pausing_at(edge);
    return;
  }
  if (known < 0) known = det_line_of((uintptr_t)__builtin_return_address(0), name, sizeof name);
  int length;
  if (known) {
    size_t used = (size_t)snprintf(line, sizeof line, "{\"event\":\"coverage\",\"details\":{\"name\":\"");
    used = det_json_escaped(line, used, sizeof line, name);
    if (used + 4 > sizeof line) return;
    memcpy(line + used, "\"}}", 4);
    length = (int)(used + 3);
  } else {
    length = snprintf(line, sizeof line, "{\"event\":\"coverage\",\"details\":{\"name\":\"edge %u\"}}", edge);
  }
  if (length > 0) (void)!write(determinismo_coverage_device, line, (size_t)length);
  det_pausing_at(edge);
}
