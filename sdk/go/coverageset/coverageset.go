// SPDX-License-Identifier: MIT

// Package coverageset reads a node's coverage set, DETERMINISMO_COVERAGE: what of its
// instrumented code reports coverage and is a point for thread pausing (the Zig SDK's
// schema.Coverage). A comma-separated list of name prefixes, those starting with "-" excluded: a
// name is in the set when an included prefix starts it (or none is given) and no excluded one
// does. Go's names are package import paths. determinismo-toolexec reads it at build (a build
// argument), package coverage at run.
package coverageset

import "strings"

// Set is a parsed coverage set; the zero Set holds every name.
type Set struct {
	include, exclude []string
}

// Parse reads a set ("a,b,-c").
func Parse(text string) Set {
	var set Set
	for _, entry := range strings.Split(text, ",") {
		if excluded, ok := strings.CutPrefix(entry, "-"); ok {
			if excluded != "" {
				set.exclude = append(set.exclude, excluded)
			}
		} else if entry != "" {
			set.include = append(set.include, entry)
		}
	}
	return set
}

// Contains is whether the name is in the set.
func (set Set) Contains(name string) bool {
	for _, prefix := range set.exclude {
		if strings.HasPrefix(name, prefix) {
			return false
		}
	}
	if len(set.include) == 0 {
		return true
	}
	for _, prefix := range set.include {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}
