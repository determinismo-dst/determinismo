// SPDX-License-Identifier: MIT

package coverageset

import "testing"

func TestContains(t *testing.T) {
	set := Parse("go.etcd.io/etcd/server/v3,go.etcd.io/raft/v3,-go.etcd.io/etcd/server/v3/proxy")
	for name, want := range map[string]bool{
		"go.etcd.io/etcd/server/v3/etcdserver":  true,
		"go.etcd.io/raft/v3":                    true,
		"go.etcd.io/etcd/server/v3/proxy/grpc": false,
		"google.golang.org/grpc":                false,
	} {
		if set.Contains(name) != want {
			t.Errorf("Contains(%q) = %v, want %v", name, !want, want)
		}
	}
	if !Parse("").Contains("anything") {
		t.Error("the empty set holds every name")
	}
	if Parse("-vendor").Contains("vendor/x") || !Parse("-vendor").Contains("main") {
		t.Error("an exclusion alone leaves the rest")
	}
}
