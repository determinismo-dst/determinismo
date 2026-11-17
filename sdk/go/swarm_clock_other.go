// SPDX-License-Identifier: MIT

//go:build !linux

package determinismo

// monotonicMs: outside Linux there is no determinismo, no swarm seed, and so no table to time.
func monotonicMs() uint64 { return 0 }

func monotonicNs() uint64 { return 0 }
