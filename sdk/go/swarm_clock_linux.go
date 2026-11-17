// SPDX-License-Identifier: MIT

//go:build linux

package determinismo

import (
	"syscall"
	"unsafe"
)

// monotonicMs is CLOCK_MONOTONIC in milliseconds, as the other SDKs read it: the same stretches
// in every process of a timeline.
func monotonicMs() uint64 {
	var now syscall.Timespec
	const clockMonotonic = 1
	syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockMonotonic, uintptr(unsafe.Pointer(&now)), 0)
	return uint64(now.Sec)*1000 + uint64(now.Nsec)/1_000_000
}

// monotonicNs is CLOCK_MONOTONIC in nanoseconds: virtual time inside determinismo, the fault
// injector's clock (a crash point's request names its moment in it).
func monotonicNs() uint64 {
	var now syscall.Timespec
	const clockMonotonic = 1
	syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockMonotonic, uintptr(unsafe.Pointer(&now)), 0)
	return uint64(now.Sec)*1_000_000_000 + uint64(now.Nsec)
}
