// SPDX-License-Identifier: MIT

// determinismo-toolexec instruments Go programs for determinismo as they build, with no change
// to their code or their go.mod:
//
//	GOFLAGS=-toolexec=determinismo-toolexec DETERMINISMO_SDK_DIR=<sdk/go> go build ./...
//
// Every block of every package but the standard library's (and this SDK's) starts with a call
// to the SDK's coverage.Block, on its first line (line numbers stay the program's): each block
// reports itself once, as its source line, and every pass is where thread pausing may pause the
// goroutine (package coverage). DETERMINISMO_INSTRUMENT, import path prefixes separated by
// commas, narrows it to those packages.
//
// The compiler and the linker are given the SDK's packages (its export data, from `go list
// -export` in DETERMINISMO_SDK_DIR, cached in the temporary directory); the compiler's version
// line carries this tool's and the SDK's hash, so the build cache keeps instrumented packages
// apart from plain ones.
//
// Build flags that change how packages compile (-tags, -trimpath, -gcflags) belong in GOFLAGS
// (`GOFLAGS="-tags=jemalloc -trimpath -toolexec=determinismo-toolexec"`), not on go build's
// command line: the tools never see the command line, and the SDK's packages, built with the
// GOFLAGS this tool is given, must be compiled as the program's or the link refuses them
// ("fingerprint mismatch": Dolt's -tags timetzdata, Weaviate's -trimpath, 2026-11-17). The link's
// failure says so.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"hash/fnv"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/determinismo-dst/determinismo/sdk/go/coverageset"
)

const (
	sdkPath      = "github.com/determinismo-dst/determinismo/sdk/go"
	coveragePath = sdkPath + "/coverage"
	alias        = "__determinismoCoverage"
)

// The rewritten files and import configurations, removed once the tool ran.
var temporary []string

func temporaryDirectory() (string, error) {
	directory, err := os.MkdirTemp("", "determinismo-toolexec-")
	if err == nil {
		temporary = append(temporary, directory)
	}
	return directory, err
}

func exit(code int) {
	for _, directory := range temporary {
		os.RemoveAll(directory)
	}
	os.Exit(code)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: determinismo-toolexec <tool> <arguments>... (as go build's -toolexec)")
		os.Exit(2)
	}
	tool, arguments := os.Args[1], os.Args[2:]
	name := strings.TrimSuffix(filepath.Base(tool), ".exe")
	instrumenting := name == "compile" || name == "link"
	if instrumenting && len(arguments) == 1 && strings.HasPrefix(arguments[0], "-V") {
		version(tool, arguments)
		return
	}
	var err error
	switch name {
	case "compile":
		arguments, err = compile(tool, arguments)
	case "link":
		arguments, err = link(tool, arguments)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "determinismo-toolexec: %s: %v\n", name, err)
		exit(1)
	}
	command := exec.Command(tool, arguments...)
	var said bytes.Buffer
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
	if name == "link" {
		command.Stderr = io.MultiWriter(os.Stderr, &said)
	}
	if err := command.Run(); err != nil {
		if hint := linkHint(said.Bytes()); hint != "" {
			fmt.Fprintln(os.Stderr, hint)
		}
		if failed, ok := err.(*exec.ExitError); ok {
			exit(failed.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "determinismo-toolexec: %v\n", err)
		exit(1)
	}
	exit(0)
}

// linkHint is what to do about a failed link's output, "" when this tool has nothing to say: a
// fingerprint mismatch is the SDK's packages compiled with other flags than the program's.
func linkHint(output []byte) string {
	if !bytes.Contains(output, []byte("fingerprint mismatch")) {
		return ""
	}
	return "determinismo-toolexec: the SDK's packages were compiled with other build flags than the " +
		"program's: put those that change how packages compile (-tags, -trimpath, -gcflags) in GOFLAGS " +
		"(GOFLAGS=\"-tags=<tags> -trimpath -toolexec=determinismo-toolexec\"), not on go build's " +
		"command line, which the tools never see"
}

// version prints the tool's version line with this tool's and the SDK's hash appended: for a
// release, the go command keys its cache on the whole line.
func version(tool string, arguments []string) {
	output, err := exec.Command(tool, arguments...).Output()
	if err != nil {
		fmt.Fprintf(os.Stderr, "determinismo-toolexec: %s %s: %v\n", tool, arguments[0], err)
		os.Exit(1)
	}
	line := strings.TrimSpace(string(output))
	if strings.Contains(line, " devel ") {
		fmt.Println(line) // A development toolchain's line ends in its build ID: left as it is.
		return
	}
	fmt.Printf("%s determinismo:%s\n", line, identity())
}

// identity is a hash of this tool's binary and the SDK's sources.
func identity() string {
	hash := sha256.New()
	if self, err := os.Executable(); err == nil {
		if contents, err := os.ReadFile(self); err == nil {
			hash.Write(contents)
		}
	}
	for _, file := range sdkSources() {
		if contents, err := os.ReadFile(file); err == nil {
			hash.Write([]byte(file))
			hash.Write(contents)
		}
	}
	return hex.EncodeToString(hash.Sum(nil)[:8])
}

func sdkSources() []string {
	directory := os.Getenv("DETERMINISMO_SDK_DIR")
	if directory == "" {
		return nil
	}
	var files []string
	for _, pattern := range []string{"*.go", "coverage/*.go", "go.mod"} {
		matches, _ := filepath.Glob(filepath.Join(directory, pattern))
		files = append(files, matches...)
	}
	sort.Strings(files)
	return files
}

// compile instruments the package's files when it is one to instrument: its arguments then name
// the rewritten files and an import configuration that has the SDK.
func compile(tool string, arguments []string) ([]string, error) {
	pkg, importcfg, std := "", -1, false
	for index, argument := range arguments {
		switch {
		case argument == "-std":
			std = true
		case argument == "-p" && index+1 < len(arguments):
			pkg = arguments[index+1]
		case argument == "-importcfg" && index+1 < len(arguments):
			importcfg = index + 1
		}
	}
	if std || pkg == "" || importcfg < 0 || !wanted(pkg) {
		return arguments, nil
	}
	directory, err := temporaryDirectory()
	if err != nil {
		return nil, err
	}
	rewritten := false
	for index, argument := range arguments {
		if !strings.HasSuffix(argument, ".go") || strings.HasPrefix(argument, "-") {
			continue
		}
		base := filepath.Base(argument)
		if strings.HasPrefix(base, "_cgo_") {
			continue // cgo's generated declarations.
		}
		output, changed, err := instrument(pkg, argument, filepath.Join(directory, fmt.Sprintf("%d-%s", index, base)))
		if err != nil {
			return nil, err
		}
		if changed {
			arguments[index] = output
			rewritten = true
		}
	}
	if !rewritten {
		return arguments, nil
	}
	configuration, err := importcfgWithSDK(arguments[importcfg], directory)
	if err != nil {
		return nil, err
	}
	arguments[importcfg] = configuration
	return arguments, nil
}

// link gives the linker the SDK's packages too (an instrumented program imports them).
func link(tool string, arguments []string) ([]string, error) {
	for index, argument := range arguments {
		if argument == "-importcfg" && index+1 < len(arguments) {
			directory, err := temporaryDirectory()
			if err != nil {
				return nil, err
			}
			configuration, err := importcfgWithSDK(arguments[index+1], directory)
			if err != nil {
				return nil, err
			}
			arguments[index+1] = configuration
		}
	}
	return arguments, nil
}

// wanted is whether to instrument a package: DETERMINISMO_INSTRUMENT's prefixes (every package
// when empty), and in the node's coverage set, DETERMINISMO_COVERAGE (a build argument: what it
// leaves out costs nothing at run).
func wanted(pkg string) bool {
	if pkg == sdkPath || strings.HasPrefix(pkg, sdkPath+"/") {
		return false
	}
	if !coverageset.Parse(os.Getenv("DETERMINISMO_COVERAGE")).Contains(pkg) {
		return false
	}
	prefixes := os.Getenv("DETERMINISMO_INSTRUMENT")
	if prefixes == "" {
		return true
	}
	for _, prefix := range strings.Split(prefixes, ",") {
		if prefix != "" && strings.HasPrefix(pkg, prefix) {
			return true
		}
	}
	return false
}

// instrument writes `path` (of package `pkg`) with a call at the start of each block and case to
// `output`, a line directive first so positions stay the original file's. False when it has no
// block.
func instrument(pkg, path, output string) (string, bool, error) {
	source, err := os.ReadFile(path)
	if err != nil {
		return "", false, err
	}
	files := token.NewFileSet()
	file, err := parser.ParseFile(files, path, source, parser.ParseComments)
	if err != nil {
		return "", false, err
	}
	place, err := filepath.Abs(path)
	if err != nil {
		place = path
	}
	type insertion struct {
		offset int
		text   string
	}
	var insertions []insertion
	guards := "__determinismoGuards" + hashOf(place)[:8]
	count := 0
	probe := func(at token.Pos) {
		position := files.Position(at)
		id := fnv.New64a()
		fmt.Fprintf(id, "%s:%d", place, position.Offset)
		line := fmt.Sprintf("%s:%d", place, position.Line)
		text := fmt.Sprintf(" %s.Block(&%s[%d], %#x, %q);", alias, guards, count, id.Sum64(), line)
		insertions = append(insertions, insertion{position.Offset, text})
		count++
	}
	// A switch's or select's own braces hold cases, not statements: their cases are probed.
	cases := map[*ast.BlockStmt]bool{}
	ast.Inspect(file, func(node ast.Node) bool {
		switch node := node.(type) {
		case *ast.FuncDecl:
			if node.Body == nil || runtimeDirective(node.Doc) {
				return false // Code the runtime calls where a call may not be (nosplit).
			}
		case *ast.SwitchStmt:
			cases[node.Body] = true
		case *ast.TypeSwitchStmt:
			cases[node.Body] = true
		case *ast.SelectStmt:
			cases[node.Body] = true
		case *ast.IfStmt:
			// An if with no else gets one, a block of its own inserted after the body's brace on
			// its line: the direction not taken is a behavior too (`if err != nil { return err }`
			// skipped a thousand times, then taken once), counted across the run's timelines by
			// the explorer as any line.
			if node.Else == nil && node.Body != nil {
				position := files.Position(node.Body.Rbrace + 1)
				id := fnv.New64a()
				fmt.Fprintf(id, "%s:%d:else", place, position.Offset)
				text := fmt.Sprintf(" else { %s.Block(&%s[%d], %#x, %q) }", alias, guards, count,
					id.Sum64(), fmt.Sprintf("%s:%d", place, position.Line))
				insertions = append(insertions, insertion{position.Offset, text})
				count++
			}
		case *ast.BlockStmt:
			if !cases[node] {
				probe(node.Lbrace + 1)
			}
		case *ast.CaseClause:
			probe(node.Colon + 1)
		case *ast.CommClause:
			probe(node.Colon + 1)
		}
		return true
	})
	if count == 0 {
		return "", false, nil
	}
	// The import on the package clause's line: no line moves.
	insertions = append(insertions, insertion{
		files.Position(file.Name.End()).Offset,
		fmt.Sprintf("; import %s %q", alias, coveragePath),
	})
	sort.Slice(insertions, func(a, b int) bool { return insertions[a].offset > insertions[b].offset })
	text := source
	for _, at := range insertions {
		text = append(text[:at.offset], append([]byte(at.text), text[at.offset:]...)...)
	}
	var result bytes.Buffer
	fmt.Fprintf(&result, "//line %s:1\n", place)
	result.Write(text)
	fmt.Fprintf(&result, "\nvar %s [%d]uint32\n", guards, count)
	// Its places in the binary's shared bitmap, as its package initializes (coverage.Register),
	// and whether the node's coverage set holds its package.
	fmt.Fprintf(&result, "var _ = %s.Register(%s[:], %q)\n", alias, guards, pkg)
	if err := os.WriteFile(output, result.Bytes(), 0o644); err != nil {
		return "", false, err
	}
	return output, true, nil
}

// runtimeDirective is whether a function's comments ask for what a call breaks (no stack
// growth, the system stack, no write barriers).
func runtimeDirective(comments *ast.CommentGroup) bool {
	if comments == nil {
		return false
	}
	for _, comment := range comments.List {
		for _, directive := range []string{"//go:nosplit", "//go:systemstack", "//go:nowritebarrier", "//go:norace"} {
			if strings.HasPrefix(comment.Text, directive) {
				return true
			}
		}
	}
	return false
}

func hashOf(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// importcfgWithSDK is `path` with the SDK's packages added (those it lacks), written in
// `directory`.
func importcfgWithSDK(path, directory string) (string, error) {
	original, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	entries, err := sdkPackageFiles()
	if err != nil {
		return "", err
	}
	known := map[string]bool{}
	for _, line := range strings.Split(string(original), "\n") {
		if fields := strings.SplitN(strings.TrimPrefix(line, "packagefile "), "=", 2); len(fields) == 2 {
			known[fields[0]] = true
		}
	}
	var configuration bytes.Buffer
	configuration.Write(original)
	if len(original) > 0 && original[len(original)-1] != '\n' {
		configuration.WriteByte('\n')
	}
	for _, entry := range entries {
		fields := strings.SplitN(strings.TrimPrefix(entry, "packagefile "), "=", 2)
		if len(fields) == 2 && !known[fields[0]] {
			configuration.WriteString(entry + "\n")
		}
	}
	output := filepath.Join(directory, filepath.Base(path))
	return output, os.WriteFile(output, configuration.Bytes(), 0o644)
}

// sdkPackageFiles are importcfg lines for the coverage package and everything it imports, from
// `go list -export` in the SDK's module (built without this tool), cached by what they depend on.
func sdkPackageFiles() ([]string, error) {
	directory := os.Getenv("DETERMINISMO_SDK_DIR")
	if directory == "" {
		return nil, fmt.Errorf("DETERMINISMO_SDK_DIR is not set (the SDK's sdk/go directory)")
	}
	goroot := os.Getenv("GOROOT")
	if goroot == "" {
		if output, err := exec.Command("go", "env", "GOROOT").Output(); err == nil {
			goroot = strings.TrimSpace(string(output))
		}
	}
	gobin := filepath.Join(goroot, "bin", "go")
	flags := []string{}
	race := false
	for _, flag := range strings.Fields(os.Getenv("GOFLAGS")) {
		if !strings.HasPrefix(flag, "-toolexec") {
			flags = append(flags, flag)
		}
		race = race || flag == "-race"
	}
	// A race build (`go build -race`: the flag reaches the tools, not GOFLAGS) needs the SDK's
	// packages built with it too, or the link refuses them ("fingerprint mismatch": etcd's race
	// profile, 2026-11-09).
	if !race {
		for _, argument := range os.Args[1:] {
			if argument == "-race" {
				flags = append(flags, "-race")
				break
			}
		}
	}
	key := strings.Join([]string{gobin, os.Getenv("GOOS"), os.Getenv("GOARCH"),
		os.Getenv("CGO_ENABLED"), strings.Join(flags, " "), directory, identity()}, "\x00")
	cache := filepath.Join(os.TempDir(), "determinismo-toolexec-"+hashOf(key)[:16]+".importcfg")
	if cached, err := os.ReadFile(cache); err == nil {
		return strings.Split(strings.TrimSpace(string(cached)), "\n"), nil
	}
	command := exec.Command(gobin, "list", "-export", "-deps",
		"-f", "{{if .Export}}packagefile {{.ImportPath}}={{.Export}}{{end}}", "./coverage")
	command.Dir = directory
	command.Env = append(os.Environ(), "GOFLAGS="+strings.Join(flags, " "))
	command.Stderr = os.Stderr
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("go list -export in %s: %w", directory, err)
	}
	var entries []string
	for _, line := range strings.Split(string(output), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			entries = append(entries, line)
		}
	}
	partial := fmt.Sprintf("%s.%d", cache, os.Getpid())
	if os.WriteFile(partial, []byte(strings.Join(entries, "\n")+"\n"), 0o644) == nil {
		os.Rename(partial, cache)
	}
	return entries, nil
}
