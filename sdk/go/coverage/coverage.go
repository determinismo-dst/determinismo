// SPDX-License-Identifier: MIT

// Package coverage is what determinismo-toolexec's instrumentation calls at the start of every
// block of the packages it instruments (cmd/determinismo-toolexec): each block reports itself
// once a timeline, a "coverage" event named by its source line ("line <file>:<n>"), as the C
// and Zig SDKs do for edges; and every pass through one is a point where thread pausing may
// pause the goroutine. Inside determinismo only.
//
// The node's coverage set (DETERMINISMO_COVERAGE, package import paths) narrows it at run: a
// package it leaves out reports nothing and is no pausing point (its blocks still call Block,
// which returns at once; determinismo-toolexec leaves it uninstrumented when the set is a build
// argument too, as determinismo passes it).
//
// Once a timeline, not once a process: each instrumented file registers its blocks' guards as
// its package initializes (Register), in the same order in every process of a binary, so each
// block has a place in a bitmap the binary's processes share (/opt/determinismo/coverage, as
// the C SDK's): a process started again (a node restarted) reports only what none did. A block
// run before its file registered (a package variable's initializer) reports per process.
//
// Thread pausing, as the C SDK's det_pausing_at: one stretch of two seconds (virtual time) in
// four, a named decision ("thread pausing") at the stretch's first look, one block in 64 is a
// slow point with its own pause (1 to 10 ms), drawn for the stretch: a goroutine reaching one
// waits there, at most 8 times a stretch. Goroutines that reach a slow point wait there
// together, so the checks of a check-then-act between them all run before any of its acts. The
// clock is read every 4096 passes of all goroutines.
package coverage

import (
	"bytes"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	determinismo "github.com/determinismo-dst/determinismo/sdk/go"
	"github.com/determinismo-dst/determinismo/sdk/go/coverageset"
)

const (
	passesPerLook = 4096
	pausesMax     = 8
	stretchNanos  = 2 * int64(time.Second)
)

var (
	inside = determinismo.Inside()
	passes atomic.Uint32
	// The stretch drawn (its 2-second count since the process started, plus one; 0 before any)
	// and its seed (odd; 0 when it pauses nothing).
	stretch atomic.Int64
	seed    atomic.Uint64
	drawing sync.Mutex
	started = time.Now()
	// Pauses per goroutine in the current stretch, by goroutine id.
	pausesLock sync.Mutex
	pauses     = map[uint64]pausesCount{}
)

type pausesCount struct {
	stretch int64
	count   int
}

// A guard's values: its block not run yet, reported, or left out of the node's coverage set.
const (
	guardNew      = 0
	guardReported = 1
	guardExcluded = 2
)

// The node's coverage set (coverageset: DETERMINISMO_COVERAGE), by package: a block of a package
// it leaves out reports nothing and pauses nothing.
var set = coverageset.Parse(os.Getenv("DETERMINISMO_COVERAGE"))

// Block is called at the start of each instrumented block: `guard` is its file's slot for it
// (guardNew until reported), `id` its number, `place` its source line ("<file>:<n>").
func Block(guard *uint32, id uint64, place string) {
	if !inside {
		return
	}
	state := atomic.LoadUint32(guard)
	if state == guardExcluded {
		return
	}
	if state == guardNew && atomic.CompareAndSwapUint32(guard, guardNew, guardReported) && !reportedBefore(guard) {
		determinismo.Event("coverage", map[string]any{"name": "line " + place})
	}
	pausing(id)
}

// The bitmap of the binary's blocks the timeline reported, and where each file's guards are in
// it (sorted by address).
const sharedBits = 1 << 24

var (
	sharedLock  sync.Mutex
	sharedMap   []byte
	sharedNext  uintptr
	sharedFiles []sharedFile
)

type sharedFile struct{ start, end, base uintptr }

// Register gives a file's guards their places in the shared bitmap, or leaves them out when the
// node's coverage set leaves out their package (the instrumentation calls it as the file's
// package initializes; the value is for `var _ =`).
func Register(guards []uint32, pkg string) struct{} {
	if !inside || len(guards) == 0 {
		return struct{}{}
	}
	if !set.Contains(pkg) {
		for index := range guards {
			atomic.StoreUint32(&guards[index], guardExcluded)
		}
		return struct{}{}
	}
	sharedLock.Lock()
	defer sharedLock.Unlock()
	if sharedMap == nil {
		sharedMap = sharedOpen()
	}
	start := uintptr(unsafe.Pointer(&guards[0]))
	file := sharedFile{start: start, end: start + uintptr(len(guards))*4, base: sharedNext}
	sharedNext += uintptr(len(guards))
	at := sort.Search(len(sharedFiles), func(i int) bool { return sharedFiles[i].start > start })
	sharedFiles = append(sharedFiles, sharedFile{})
	copy(sharedFiles[at+1:], sharedFiles[at:])
	sharedFiles[at] = file
	return struct{}{}
}

// sharedOpen maps the binary's bitmap: /opt/determinismo/coverage/sdk-go-<the executable's
// device, inode and size> (a timeline's files name its builds); nil when it cannot.
func sharedOpen() []byte {
	info, err := os.Stat("/proc/self/exe")
	if err != nil {
		return nil
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	path := fmt.Sprintf("/opt/determinismo/coverage/sdk-go-%x-%x-%x", stat.Dev, stat.Ino, stat.Size)
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o666)
	if err != nil {
		return nil
	}
	defer file.Close()
	if file.Truncate(sharedBits/8) != nil {
		return nil
	}
	bits, err := syscall.Mmap(int(file.Fd()), 0, sharedBits/8, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return nil
	}
	return bits
}

// reportedBefore is whether a process of the timeline reported this block before (this one has
// now): false for a block whose file has not registered, or past the bitmap.
func reportedBefore(guard *uint32) bool {
	at := uintptr(unsafe.Pointer(guard))
	sharedLock.Lock()
	defer sharedLock.Unlock()
	if sharedMap == nil {
		return false
	}
	i := sort.Search(len(sharedFiles), func(i int) bool { return sharedFiles[i].end > at })
	if i == len(sharedFiles) || at < sharedFiles[i].start {
		return false
	}
	index := sharedFiles[i].base + (at-sharedFiles[i].start)/4
	if index >= sharedBits {
		return false
	}
	word := (*uint32)(unsafe.Pointer(&sharedMap[index/32*4]))
	bit := uint32(1) << (index % 32)
	for {
		old := atomic.LoadUint32(word)
		if old&bit != 0 {
			return true
		}
		if atomic.CompareAndSwapUint32(word, old, old|bit) {
			return false
		}
	}
}

func pausing(id uint64) {
	if passes.Add(1)%passesPerLook == 1 {
		look()
	}
	drawn := seed.Load()
	if drawn == 0 {
		return
	}
	value := (drawn ^ id) * 0x9e3779b97f4a7c15 // The block's draw for the stretch.
	value ^= value >> 29
	value *= 0xbf58476d1ce4e5b9
	value ^= value >> 32
	if value%64 != 0 {
		return
	}
	current := stretch.Load()
	goroutine := goroutineID()
	pausesLock.Lock()
	counted := pauses[goroutine]
	if counted.stretch != current {
		counted = pausesCount{stretch: current}
	}
	if counted.count == pausesMax {
		pausesLock.Unlock()
		return
	}
	counted.count++
	pauses[goroutine] = counted
	pausesLock.Unlock()
	time.Sleep(time.Duration(1+(value>>8)%10) * time.Millisecond)
}

// look draws a new stretch when the clock says so (the goroutines that look meanwhile go on with
// the last one).
func look() {
	current := int64(time.Since(started))/stretchNanos + 1 // Virtual time inside determinismo.
	if stretch.Load() == current || !drawing.TryLock() {
		return
	}
	defer drawing.Unlock()
	if stretch.Load() == current {
		return
	}
	var drawn uint64
	if determinismo.RandomBelowNamed("thread pausing", 4) == 0 {
		drawn = determinismo.RandomU64() | 1
	}
	seed.Store(drawn)
	stretch.Store(current)
	pausesLock.Lock()
	clear(pauses)
	pausesLock.Unlock()
}

// goroutineID is the calling goroutine's number, from its stack's header ("goroutine 7 [...").
// Only at slow points: Go gives goroutines no identity cheaper to read.
func goroutineID() uint64 {
	var buffer [64]byte
	header := buffer[:runtime.Stack(buffer[:], false)]
	header = bytes.TrimPrefix(header, []byte("goroutine "))
	if end := bytes.IndexByte(header, ' '); end > 0 {
		header = header[:end]
	}
	id, _ := strconv.ParseUint(string(header), 10, 64)
	return id
}
