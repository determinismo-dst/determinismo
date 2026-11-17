// SPDX-License-Identifier: MIT

// Package run is one run of the race: 64 goroutines, each incrementing the counter if it is
// still zero. Only this package is instrumented (DETERMINISMO_INSTRUMENT=race/run).
package run

import "sync"

const goroutines = 64

var counter int

func update() {
	if counter == 0 {
		counter++
	}
}

// Run is one run: its counter, or a panic when every goroutine incremented it.
func Run() int {
	var group sync.WaitGroup
	for range goroutines {
		group.Add(1)
		go func() {
			defer group.Done()
			update()
		}()
	}
	group.Wait()
	if counter == goroutines {
		panic("all 64 goroutines incremented the counter")
	}
	return counter
}
