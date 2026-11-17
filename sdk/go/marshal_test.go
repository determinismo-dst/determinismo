// SPDX-License-Identifier: MIT

package determinismo

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestMarshalKindFirst(t *testing.T) {
	for message, want := range map[*map[string]any]string{
		{"event": "coverage", "details": map[string]any{"name": "line a.go:1"}}: `{"event":"coverage","details":{"name":"line a.go:1"}}`,
		{"lifecycle": "setup_complete", "details": map[string]any{}}:          `{"lifecycle":"setup_complete","details":{}}`,
		{"assert": map[string]any{"type": "always"}}:                          `{"assert":{"type":"always"}}`,
	} {
		data, err := marshal(*message)
		if err != nil || string(data) != want {
			t.Errorf("marshal(%v) = %s, %v; want %s", *message, data, err, want)
		}
	}
}

func TestDetailsCutFitsAndKeepsWholeRunes(t *testing.T) {
	text := strings.Repeat("line é€ \"quoted\"\n", 400)
	cut := detailsCut(text, 300)
	encoded, _ := json.Marshal(cut)
	if len(encoded) > 300 {
		t.Fatalf("encoded cut is %d bytes, room 300", len(encoded))
	}
	if !strings.HasPrefix(cut, "<details cut> line é€") {
		t.Fatalf("cut starts %q", cut[:20])
	}
	if !utf8.ValidString(cut) {
		t.Fatal("cut splits a rune")
	}
	if small := detailsCut("{}", 300); small != "<details cut> {}" {
		t.Fatalf("a short text is kept whole: %q", small)
	}
}
