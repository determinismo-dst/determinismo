// SPDX-License-Identifier: MIT

package main

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Every block probes alone (coverage.Block); an if without an else gets one, on its body's
// closing line, so that the direction not taken is a block too.
func TestInstrumentGivesIfWithoutElseItsElse(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "a.go")
	program := "package a\n\nfunc f(x int) int {\n\tif x > 0 {\n\t\treturn 1\n\t} else {\n\t\treturn 2\n\t}\n}\n\nfunc g(x int) int {\n\tif x > 0 {\n\t\treturn 1\n\t}\n\treturn 0\n}\n"
	if err := os.WriteFile(source, []byte(program), 0o644); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(directory, "out.go")
	if _, ok, err := instrument("a", source, output); err != nil || !ok {
		t.Fatalf("instrument: %v %v", ok, err)
	}
	text, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	result := string(text)
	if got := strings.Count(result, ".Block("); got != 6 {
		t.Errorf("%d Block probes, want 6 (f's and g's bodies, f's if/else blocks, g's if body and its else made):\n%s", got, result)
	}
	if strings.Contains(result, ".Side(") || strings.Contains(result, "__determinismoSides") {
		t.Errorf("no sides any more (rare branch directions are the explorer's, run-wide):\n%s", result)
	}
	// g's if gets an else on its body's closing line: no line moves.
	if !strings.Contains(result, "\t} else { ") {
		t.Errorf("g's if without an else should get one on its closing line:\n%s", result)
	}
	// The instrumented file compiles (gofmt parses it): an inserted else is valid Go.
	if _, err := parser.ParseFile(token.NewFileSet(), output, nil, 0); err != nil {
		t.Errorf("the instrumented file does not parse: %v\n%s", err, result)
	}
}

func TestLinkHint(t *testing.T) {
	mismatch := []byte("link: fingerprint mismatch: fmt has 49b82d1825e59da6, import from github.com/determinismo-dst/determinismo/sdk/go/coverage expecting 2467aea0d8b66a43")
	if hint := linkHint(mismatch); !strings.Contains(hint, "GOFLAGS") {
		t.Fatalf("a fingerprint mismatch's hint should name GOFLAGS: %q", hint)
	}
	if hint := linkHint([]byte("undefined: main.main")); hint != "" {
		t.Fatalf("another failure has no hint: %q", hint)
	}
}
