// SPDX-License-Identifier: MIT
// etcd-raft-node: one node of a replicated log over go.etcd.io/raft/v3's RawNode, for
// etcd-io/raft#558 (a follower crash during a joint membership change). Its storage follows the
// library's README (README.md:117): each Ready's entries written and synced to their own file
// first, then its HardState written and synced to another, two separate durable writes; the
// MemoryStorage repopulated from both at a start. Its state machine is the applied entries'
// digests by index, rebuilt at each start from the committed log.
//
// Its durability points and steps are JSON lines on standard output, for `determinismo quint`
// (a line's "msg" its action, its other fields the action's argument; examples/etcd-raft-joint's
// spec): start (what it loaded), entries (each Ready's entries written: first, last, the last's
// term, the indexes of configuration changes among them), hardstate (written), apply (an entry
// applied: index, term, conf), conf (a configuration applied: voters, outgoing), role (a change).
//
// -async-writes: raft.Config.AsyncStorageWrites (the library's doc.go, "Usage with Asynchronous
// Storage Writes"): the Ready's local storage messages handed to an append thread (entries, then
// HardState, each synced, as above; then the message's responses delivered) and an apply thread
// (committed entries applied, then its responses); no Advance. storageAppend is the append's
// own function: etcd-io/raft#551's walk holds the append thread there.
//
// Client API (a JSON object a line on -client):
//
//	{"op":"state"}                      → {"id","term","lead","commit","applied","voters","outgoing","last"}
//	{"op":"propose","data":"<text>"}    → {"ok":true} (proposed, not committed)
//	{"op":"joint","add":[4,5],"remove":[2,3]} → a ConfChangeV2 entering and leaving a joint
//	                                      configuration automatically (the issue's change)
//	{"op":"digest","index":N}           → {"index","term","digest"} of the applied entry at N
//	{"op":"campaign"}                   → this node campaigns
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"hash/crc32"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.etcd.io/raft/v3"
	pb "go.etcd.io/raft/v3/raftpb"
	"google.golang.org/protobuf/proto"
)

type applied struct {
	term   uint64
	digest uint32
}

type node struct {
	id      uint64
	rn      *raft.RawNode
	storage *raft.MemoryStorage
	dir     string
	entries *os.File

	mu       sync.Mutex
	proposed []func(*raft.RawNode)
	inbox    []*pb.Message

	peers map[uint64]string
	links map[uint64]chan *pb.Message

	// What the state machine applied, by index (1-based; 0 unused).
	log      []applied
	appliedN uint64

	// -async-writes: the local storage messages for the append and apply threads, in order.
	async    bool
	toAppend chan *pb.Message
	toApply  chan *pb.Message
}

// options are a node's flags.
type options struct {
	id          uint64
	peers       map[uint64]string
	initial     string
	dir         string
	preVote     bool
	checkQuorum bool
	async       bool
}

func main() {
	id := flag.Uint64("id", 0, "this node's id (1-5)")
	peersFlag := flag.String("peers", "", "id=host:port,... for every node")
	initial := flag.String("initial", "1,2,3", "the initial voters (bootstrapped by those of them that start fresh)")
	dataDir := flag.String("data", "/var/lib/etcd-raft-node", "the log and HardState files")
	client := flag.String("client", "0.0.0.0:8400", "the client API's address")
	listen := flag.String("listen", "0.0.0.0:9000", "the raft transport's address")
	preVote := flag.Bool("pre-vote", false, "raft.Config.PreVote")
	checkQuorum := flag.Bool("check-quorum", false, "raft.Config.CheckQuorum")
	async := flag.Bool("async-writes", false, "raft.Config.AsyncStorageWrites, an append thread and an apply thread")
	flag.Parse()

	o := options{id: *id, peers: map[uint64]string{}, initial: *initial, dir: *dataDir, preVote: *preVote, checkQuorum: *checkQuorum, async: *async}
	for _, part := range strings.Split(*peersFlag, ",") {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			continue
		}
		pid, err := strconv.ParseUint(kv[0], 10, 64)
		if err != nil {
			log.Fatalf("peer %q: %v", part, err)
		}
		o.peers[pid] = kv[1]
	}
	n, fresh := newNode(o)
	go n.serveTransport(*listen)
	go n.serveClient(*client)
	log.Printf("etcd-raft-node %d ready: fresh=%v entries=%d async=%v", n.id, fresh, n.lastIndex(), n.async)
	hs, _, _ := n.storage.InitialState()
	trace("start", map[string]any{"last": n.lastIndex(), "commit": hs.GetCommit(), "term": hs.GetTerm(), "fresh": fresh})
	n.run()
}

// newNode loads a node's files and makes its RawNode (bootstrapped when fresh and an initial
// voter), its senders and, with async writes, its append and apply threads.
func newNode(o options) (*node, bool) {
	n := &node{id: o.id, dir: o.dir, peers: o.peers, links: map[uint64]chan *pb.Message{}, log: []applied{{}}, async: o.async}
	if err := os.MkdirAll(n.dir, 0o755); err != nil {
		log.Fatal(err)
	}
	n.storage = raft.NewMemoryStorage()
	fresh := n.load()
	cfg := &raft.Config{
		ID:                 n.id,
		ElectionTick:       10,
		HeartbeatTick:      1,
		Storage:            n.storage,
		MaxSizePerMsg:      1 << 20,
		MaxInflightMsgs:    256,
		PreVote:            o.preVote,
		CheckQuorum:        o.checkQuorum,
		AsyncStorageWrites: o.async,
	}
	rn, err := raft.NewRawNode(cfg)
	if err != nil {
		log.Fatal(err)
	}
	n.rn = rn
	if fresh {
		var peers []raft.Peer
		inInitial := false
		for _, part := range strings.Split(o.initial, ",") {
			pid, err := strconv.ParseUint(part, 10, 64)
			if err != nil {
				continue
			}
			peers = append(peers, raft.Peer{ID: pid})
			if pid == n.id {
				inInitial = true
			}
		}
		// The initial voters bootstrap; the others start empty and receive the log once added.
		if inInitial {
			if err := rn.Bootstrap(peers); err != nil {
				log.Fatal(err)
			}
		}
	}
	for pid := range n.peers {
		if pid != n.id {
			ch := make(chan *pb.Message, 4096)
			n.links[pid] = ch
			go n.sender(pid, ch)
		}
	}
	if n.async {
		n.toAppend = make(chan *pb.Message, 4096)
		n.toApply = make(chan *pb.Message, 4096)
		go n.appendThread()
		go n.applyThread()
	}
	return n, fresh
}

func (n *node) lastIndex() uint64 {
	last, _ := n.storage.LastIndex()
	return last
}

// load repopulates the MemoryStorage from the files; true when there were none.
func (n *node) load() bool {
	entriesPath := filepath.Join(n.dir, "entries")
	f, err := os.OpenFile(entriesPath, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	n.entries = f
	fresh := true
	var all []*pb.Entry
	// Where the last whole record ends: the torn tail after it is cut off below.
	var good int64
	reader := bufio.NewReader(f)
	for {
		var size uint32
		if err := binary.Read(reader, binary.BigEndian, &size); err != nil {
			break
		}
		// Zeros: an append whose size a power loss kept and its data not (ext4 orders only a
		// new block's data), the torn end as a short record is. Read as an entry at index 0 it
		// dropped every earlier one (run 1447: "commit 260 is out of range [0, 0]").
		if size == 0 {
			break
		}
		buf := make([]byte, size)
		if _, err := io.ReadFull(reader, buf); err != nil {
			break // A torn record at the end: not written whole, not synced.
		}
		e := &pb.Entry{}
		if err := proto.Unmarshal(buf, e); err != nil || e.GetIndex() == 0 {
			break
		}
		good += 4 + int64(size)
		fresh = false
		// A later record at an index replaces the earlier ones from there (the README's rule).
		for len(all) > 0 && all[len(all)-1].GetIndex() >= e.GetIndex() {
			all = all[:len(all)-1]
		}
		all = append(all, e)
	}
	if len(all) > 0 {
		if err := n.storage.Append(all); err != nil {
			log.Fatal(err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(n.dir, "hardstate")); err == nil && len(data) > 0 {
		hs := &pb.HardState{}
		if err := proto.Unmarshal(data, hs); err == nil {
			fresh = false
			if err := n.storage.SetHardState(hs); err != nil {
				log.Fatal(err)
			}
		}
	}
	// A HardState committing past the log is a lost write (or a misread): what the file held,
	// said before raft refuses it, so the crash state is in the timeline's own output (run
	// 1447's timeline 2: commit 260, no entry, after a power loss).
	if hs, _, err := n.storage.InitialState(); err == nil {
		last, _ := n.storage.LastIndex()
		if hs.GetCommit() > last {
			size, _ := f.Seek(0, io.SeekEnd)
			head := make([]byte, 64)
			k, _ := f.ReadAt(head, 0)
			log.Printf("load: HardState commit %d past the log's last index %d: entries file %d bytes, %d records read, first bytes %x",
				hs.GetCommit(), last, size, len(all), head[:k])
		}
	}
	// The torn tail cut off, synced, before anything is appended: appended after it, entries
	// were out of the next load's reach (run 1450's timeline 6: 44 and 45 after 8 zero bytes,
	// its HardState committing 45 over a log the reader ended at 43).
	if size, err := f.Seek(0, io.SeekEnd); err == nil && size > good {
		if err := f.Truncate(good); err != nil {
			log.Fatal(err)
		}
		if err := f.Sync(); err != nil {
			log.Fatal(err)
		}
	}
	if _, err := f.Seek(good, io.SeekStart); err != nil {
		log.Fatal(err)
	}
	return fresh
}

// trace says a step as a JSON line on standard output, unbuffered (a power loss takes nothing
// said after the write it follows).
func trace(msg string, fields map[string]any) {
	fields["msg"] = msg
	line, err := json.Marshal(fields)
	if err != nil {
		return
	}
	os.Stdout.Write(append(line, '\n'))
}

// persistEntries appends and syncs a Ready's entries: the first of the README's two writes.
//
//go:noinline
func (n *node) persistEntries(entries []*pb.Entry) {
	if len(entries) == 0 {
		return
	}
	var out []byte
	for i := range entries {
		data, err := proto.Marshal(entries[i])
		if err != nil {
			log.Fatal(err)
		}
		out = binary.BigEndian.AppendUint32(out, uint32(len(data)))
		out = append(out, data...)
	}
	if _, err := n.entries.Write(out); err != nil {
		log.Fatal(err)
	}
	if err := n.entries.Sync(); err != nil {
		log.Fatal(err)
	}
	conf := []uint64{}
	for _, e := range entries {
		if e.GetType() == pb.EntryType_EntryConfChange || e.GetType() == pb.EntryType_EntryConfChangeV2 {
			conf = append(conf, e.GetIndex())
		}
	}
	last := entries[len(entries)-1]
	trace("entries", map[string]any{"first": entries[0].GetIndex(), "last": last.GetIndex(), "term": last.GetTerm(), "conf": conf})
}

// persistHardState writes and syncs a Ready's HardState (term, vote, commit): the second write,
// after the entries'.
//
//go:noinline
func (n *node) persistHardState(hs *pb.HardState) {
	data, err := proto.Marshal(hs)
	if err != nil {
		log.Fatal(err)
	}
	path := filepath.Join(n.dir, "hardstate")
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	if _, err := f.Write(data); err != nil {
		log.Fatal(err)
	}
	if err := f.Sync(); err != nil {
		log.Fatal(err)
	}
	f.Close()
	if err := os.Rename(tmp, path); err != nil {
		log.Fatal(err)
	}
	if d, err := os.Open(n.dir); err == nil {
		d.Sync()
		d.Close()
	}
	trace("hardstate", map[string]any{"term": hs.GetTerm(), "vote": hs.GetVote(), "commit": hs.GetCommit()})
}

func (n *node) run() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	wake := time.NewTicker(5 * time.Millisecond)
	defer wake.Stop()
	for {
		select {
		case <-ticker.C:
			n.mu.Lock()
			n.rn.Tick()
			n.mu.Unlock()
		case <-wake.C:
		}
		n.mu.Lock()
		inbox := n.inbox
		n.inbox = nil
		proposed := n.proposed
		n.proposed = nil
		for i := range inbox {
			_ = n.rn.Step(inbox[i])
		}
		for _, propose := range proposed {
			propose(n.rn)
		}
		for n.rn.HasReady() {
			rd := n.rn.Ready()
			if rd.SoftState != nil {
				trace("role", map[string]any{"state": rd.SoftState.RaftState.String(), "lead": rd.SoftState.Lead, "term": n.rn.Status().Term})
			}
			if n.async {
				// The storage work goes to its threads; the rest out now (MsgVote among it:
				// etcd-io/raft#551), no Advance.
				for _, m := range rd.Messages {
					switch m.GetTo() {
					case raft.LocalAppendThread:
						n.toAppend <- m
					case raft.LocalApplyThread:
						n.toApply <- m
					default:
						n.send(m)
					}
				}
				continue
			}
			n.persistEntries(rd.Entries)
			if err := n.storage.Append(rd.Entries); err != nil {
				log.Fatal(err)
			}
			if !raft.IsEmptyHardState(rd.HardState) {
				n.persistHardState(rd.HardState)
				if err := n.storage.SetHardState(rd.HardState); err != nil {
					log.Fatal(err)
				}
			}
			for _, m := range rd.Messages {
				n.send(m)
			}
			for _, e := range rd.CommittedEntries {
				n.apply(e)
			}
			n.rn.Advance(rd)
		}
		n.mu.Unlock()
	}
}

// send queues a message to its peer (n.mu held); a full queue is the peer unreachable.
func (n *node) send(m *pb.Message) {
	if ch, ok := n.links[m.GetTo()]; ok {
		select {
		case ch <- m:
		default:
			n.rn.ReportUnreachable(m.GetTo())
		}
	}
}

// deliver hands a storage message's responses on once its work is done: this node's own stepped
// (through the inbox, as the transport's), the others sent.
func (n *node) deliver(responses []*pb.Message) {
	n.mu.Lock()
	defer n.mu.Unlock()
	for _, m := range responses {
		if m.GetTo() == n.id {
			n.inbox = append(n.inbox, m)
		} else {
			n.send(m)
		}
	}
}

func (n *node) appendThread() {
	for m := range n.toAppend {
		n.storageAppend(m)
	}
}

// storageAppend does one MsgStorageAppend: its entries, then its HardState, each written and
// synced as the synchronous path writes a Ready's; the MemoryStorage after; then its responses.
// Its own function, never inlined: the walk of etcd-io/raft#551 holds the append thread here.
//
//go:noinline
func (n *node) storageAppend(m *pb.Message) {
	if snap := m.GetSnapshot(); snap != nil && !raft.IsEmptySnap(snap) {
		log.Fatal("storageAppend: a snapshot (this node never compacts)")
	}
	n.persistEntries(m.GetEntries())
	hs := &pb.HardState{Term: proto.Uint64(m.GetTerm()), Vote: proto.Uint64(m.GetVote()), Commit: proto.Uint64(m.GetCommit())}
	if !raft.IsEmptyHardState(hs) {
		n.persistHardState(hs)
		if err := n.storage.SetHardState(hs); err != nil {
			log.Fatal(err)
		}
	}
	if err := n.storage.Append(m.GetEntries()); err != nil {
		log.Fatal(err)
	}
	n.deliver(m.GetResponses())
}

func (n *node) applyThread() {
	for m := range n.toApply {
		n.mu.Lock()
		for _, e := range m.GetEntries() {
			n.apply(e)
		}
		n.mu.Unlock()
		n.deliver(m.GetResponses())
	}
}

func (n *node) apply(e *pb.Entry) {
	index := e.GetIndex()
	for uint64(len(n.log)) <= index {
		n.log = append(n.log, applied{})
	}
	n.log[index] = applied{term: e.GetTerm(), digest: crc32.ChecksumIEEE(e.GetData())}
	if index > n.appliedN {
		n.appliedN = index
	}
	conf := e.GetType() == pb.EntryType_EntryConfChange || e.GetType() == pb.EntryType_EntryConfChangeV2
	trace("apply", map[string]any{"index": index, "term": e.GetTerm(), "conf": conf})
	var cs *pb.ConfState
	switch e.GetType() {
	case pb.EntryType_EntryConfChange:
		cc := &pb.ConfChange{}
		if err := proto.Unmarshal(e.GetData(), cc); err == nil {
			cs = n.rn.ApplyConfChange(cc)
		}
	case pb.EntryType_EntryConfChangeV2:
		cc := &pb.ConfChangeV2{}
		if err := proto.Unmarshal(e.GetData(), cc); err == nil {
			cs = n.rn.ApplyConfChange(cc)
		}
	}
	if cs != nil {
		voters, outgoing := cs.GetVoters(), cs.GetVotersOutgoing()
		if voters == nil {
			voters = []uint64{}
		}
		if outgoing == nil {
			outgoing = []uint64{}
		}
		trace("conf", map[string]any{"index": index, "voters": voters, "outgoing": outgoing})
	}
}

// The raft transport: a connection a peer, messages framed by their length.
func (n *node) sender(pid uint64, ch chan *pb.Message) {
	var conn net.Conn
	for m := range ch {
		data, err := proto.Marshal(m)
		if err != nil {
			continue
		}
		frame := binary.BigEndian.AppendUint32(nil, uint32(len(data)))
		frame = append(frame, data...)
		for attempt := 0; attempt < 2; attempt++ {
			if conn == nil {
				c, err := net.DialTimeout("tcp", n.peers[pid], time.Second)
				if err != nil {
					break
				}
				conn = c
			}
			conn.SetWriteDeadline(time.Now().Add(time.Second))
			if _, err := conn.Write(frame); err != nil {
				conn.Close()
				conn = nil
				continue
			}
			break
		}
	}
}

func (n *node) serveTransport(addr string) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			reader := bufio.NewReader(c)
			for {
				var size uint32
				if err := binary.Read(reader, binary.BigEndian, &size); err != nil {
					return
				}
				buf := make([]byte, size)
				if _, err := io.ReadFull(reader, buf); err != nil {
					return
				}
				m := &pb.Message{}
				if err := proto.Unmarshal(buf, m); err != nil {
					return
				}
				n.mu.Lock()
				n.inbox = append(n.inbox, m)
				n.mu.Unlock()
			}
		}(conn)
	}
}

type request struct {
	Op     string   `json:"op"`
	Data   string   `json:"data"`
	Add    []uint64 `json:"add"`
	Remove []uint64 `json:"remove"`
	Index  uint64   `json:"index"`
}

func (n *node) serveClient(addr string) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go n.handleClient(conn)
	}
}

func (n *node) handleClient(c net.Conn) {
	defer c.Close()
	scan := bufio.NewScanner(c)
	for scan.Scan() {
		var req request
		var resp any
		if err := json.Unmarshal(scan.Bytes(), &req); err != nil {
			resp = map[string]any{"ok": false, "err": err.Error()}
		} else {
			resp = n.handle(req)
		}
		out, _ := json.Marshal(resp)
		fmt.Fprintf(c, "%s\n", out)
	}
}

func (n *node) handle(req request) any {
	n.mu.Lock()
	defer n.mu.Unlock()
	switch req.Op {
	case "state":
		st := n.rn.Status()
		voters := st.Config.Voters[0].Slice()
		outgoing := st.Config.Voters[1].Slice()
		return map[string]any{"id": n.id, "term": st.Term, "lead": st.Lead, "state": st.RaftState.String(),
			"commit": st.Commit, "applied": n.appliedN, "voters": voters, "outgoing": outgoing, "last": n.lastIndex()}
	case "propose":
		data := []byte(req.Data)
		n.proposed = append(n.proposed, func(rn *raft.RawNode) { _ = rn.Propose(data) })
		return map[string]any{"ok": true}
	case "joint":
		var changes []*pb.ConfChangeSingle
		for _, id := range req.Add {
			changes = append(changes, &pb.ConfChangeSingle{Type: pb.ConfChangeType_ConfChangeAddNode.Enum(), NodeId: proto.Uint64(id)})
		}
		for _, id := range req.Remove {
			changes = append(changes, &pb.ConfChangeSingle{Type: pb.ConfChangeType_ConfChangeRemoveNode.Enum(), NodeId: proto.Uint64(id)})
		}
		cc := &pb.ConfChangeV2{Transition: pb.ConfChangeTransition_ConfChangeTransitionJointImplicit.Enum(), Changes: changes}
		n.proposed = append(n.proposed, func(rn *raft.RawNode) { _ = rn.ProposeConfChange(cc) })
		return map[string]any{"ok": true}
	case "digest":
		if req.Index == 0 || req.Index >= uint64(len(n.log)) || req.Index > n.appliedN {
			return map[string]any{"ok": false, "applied": n.appliedN}
		}
		a := n.log[req.Index]
		return map[string]any{"ok": true, "index": req.Index, "term": a.term, "digest": a.digest}
	case "campaign":
		n.proposed = append(n.proposed, func(rn *raft.RawNode) { _ = rn.Campaign() })
		return map[string]any{"ok": true}
	}
	return map[string]any{"ok": false, "err": "unknown op"}
}
