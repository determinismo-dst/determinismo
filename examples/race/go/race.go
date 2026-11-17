// SPDX-License-Identifier: MIT

// The 64-goroutine check-then-act race of examples/race (race.cpp's, in Go, in package run).
// Without arguments, a runner: runs again and again, each a fresh process, printing every run's
// counter. A run exits with its counter plus 10 (a panic is 2). No hint for the explorer: only
// package run is instrumented, and every run prints the same line.
package main

import (
	"fmt"
	"os"
	"os/exec"

	"race/run"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "run" {
		os.Exit(run.Run() + 10)
	}
	for runs := 1; ; runs++ {
		command := exec.Command(os.Args[0], "run")
		command.Stdout, command.Stderr = os.Stdout, os.Stderr
		err := command.Run()
		exit, exited := err.(*exec.ExitError)
		if err != nil && !exited {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if exited && exit.ExitCode() >= 10 {
			fmt.Printf("run %d: counter %d\n", runs, exit.ExitCode()-10)
		}
	}
}
