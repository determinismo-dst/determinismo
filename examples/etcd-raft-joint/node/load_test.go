// SPDX-License-Identifier: MIT
package main

import (
	"os"
	"path/filepath"
	"testing"

	"go.etcd.io/raft/v3"
	pb "go.etcd.io/raft/v3/raftpb"
	"google.golang.org/protobuf/proto"
)

// A power loss can keep an append's size and not its data: the file then ends in zeros (run
// 1447's timeline 2: 26 zero bytes after 6,313 synced ones, in a block already allocated, which
// ext4's data=ordered does not order). The log loads whole, the zeros its torn end; read as an
// entry at index 0 they dropped every entry, and raft refused the HardState's commit.
func TestLoadStopsAtAZeroTail(t *testing.T) {
	dir := t.TempDir()
	n := &node{dir: dir, storage: raft.NewMemoryStorage()}
	n.load()
	var written []*pb.Entry
	for i := uint64(1); i <= 5; i++ {
		written = append(written, &pb.Entry{Term: proto.Uint64(1), Index: proto.Uint64(i), Data: []byte("x")})
	}
	n.persistEntries(written)
	n.persistHardState(&pb.HardState{Term: proto.Uint64(1), Commit: proto.Uint64(5)})
	if _, err := n.entries.Write(make([]byte, 26)); err != nil {
		t.Fatal(err)
	}
	n.entries.Close()

	again := &node{dir: dir, storage: raft.NewMemoryStorage()}
	again.load()
	defer again.entries.Close()
	if last := again.lastIndex(); last != 5 {
		t.Fatalf("after a zero tail the log's last index is %d, want 5", last)
	}
	if _, err := os.Stat(filepath.Join(dir, "entries")); err != nil {
		t.Fatal(err)
	}
}

// The torn tail goes at the load: entries appended after it are read at the next one (run
// 1450's timeline 6: records to 43, 8 zero bytes, then 44 and 45 appended after them, which the
// next load could not reach; its HardState committed 45 and raft refused it).
func TestEntriesAfterATornTailLoad(t *testing.T) {
	dir := t.TempDir()
	n := &node{dir: dir, storage: raft.NewMemoryStorage()}
	n.load()
	entry := func(i uint64) *pb.Entry {
		return &pb.Entry{Term: proto.Uint64(1), Index: proto.Uint64(i), Data: []byte("x")}
	}
	n.persistEntries([]*pb.Entry{entry(1), entry(2), entry(3)})
	if _, err := n.entries.Write(make([]byte, 8)); err != nil {
		t.Fatal(err)
	}
	n.entries.Close()

	second := &node{dir: dir, storage: raft.NewMemoryStorage()}
	second.load()
	second.persistEntries([]*pb.Entry{entry(4), entry(5)})
	second.entries.Close()

	third := &node{dir: dir, storage: raft.NewMemoryStorage()}
	third.load()
	defer third.entries.Close()
	if last := third.lastIndex(); last != 5 {
		t.Fatalf("entries appended after a torn tail: the log's last index is %d, want 5", last)
	}
}

// The terms a node led come back at its next start (the election-safety check reads them after
// crashes); a line a power loss cut is no term.
func TestLedTermsLoad(t *testing.T) {
	dir := t.TempDir()
	n := &node{dir: dir, storage: raft.NewMemoryStorage()}
	n.load()
	n.noteLed(3)
	n.noteLed(3)
	n.noteLed(7)
	if _, err := n.led.WriteString("1"); err != nil {
		t.Fatal(err)
	}
	n.led.Close()
	n.entries.Close()

	again := &node{dir: dir, storage: raft.NewMemoryStorage()}
	again.load()
	defer again.entries.Close()
	defer again.led.Close()
	if len(again.ledTerms) != 2 || again.ledTerms[0] != 3 || again.ledTerms[1] != 7 {
		t.Fatalf("led terms after a restart: %v, want [3 7]", again.ledTerms)
	}
}
