// SPDX-License-Identifier: MIT
package main

import (
	"testing"
	"time"

	"go.etcd.io/raft/v3"
)

// The async storage writes mode: a one-node cluster campaigns, applies a proposal through its
// apply thread, and its append thread's writes load back (entries and a HardState committing
// them), as the synchronous path's do.
func TestAsyncWritesApplyAndLoad(t *testing.T) {
	dir := t.TempDir()
	n, fresh := newNode(options{id: 1, peers: map[uint64]string{1: "127.0.0.1:0"}, initial: "1", dir: dir, async: true})
	if !fresh {
		t.Fatal("a new directory loaded as not fresh")
	}
	go n.run()
	n.mu.Lock()
	n.proposed = append(n.proposed, func(rn *raft.RawNode) { _ = rn.Campaign() })
	n.mu.Unlock()
	wait := func(what string, done func() bool) {
		t.Helper()
		for start := time.Now(); time.Since(start) < 10*time.Second; time.Sleep(5 * time.Millisecond) {
			n.mu.Lock()
			ok := done()
			n.mu.Unlock()
			if ok {
				return
			}
		}
		t.Fatalf("never: %s", what)
	}
	wait("leader", func() bool { return n.rn.Status().RaftState == raft.StateLeader })
	n.mu.Lock()
	n.proposed = append(n.proposed, func(rn *raft.RawNode) { _ = rn.Propose([]byte("a")) })
	n.mu.Unlock()
	var index uint64
	wait("the proposal applied", func() bool {
		for i := uint64(1); i <= n.appliedN && i < uint64(len(n.log)); i++ {
			if n.log[i].digest != 0 && n.log[i].term >= 1 {
				index = i
			}
		}
		return index != 0
	})
	// The next load sees what the append thread wrote.
	time.Sleep(50 * time.Millisecond)
	again := &node{dir: dir, storage: raft.NewMemoryStorage()}
	again.load()
	defer again.entries.Close()
	if last := again.lastIndex(); last < index {
		t.Fatalf("loaded log ends at %d, the applied entry is at %d", last, index)
	}
	hs, _, err := again.storage.InitialState()
	if err != nil {
		t.Fatal(err)
	}
	if hs.GetCommit() < index || hs.GetVote() != 1 || hs.GetTerm() < 1 {
		t.Fatalf("loaded HardState term %d vote %d commit %d, the applied entry at %d", hs.GetTerm(), hs.GetVote(), hs.GetCommit(), index)
	}
}
