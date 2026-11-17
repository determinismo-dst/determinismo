// SPDX-License-Identifier: MIT

package determinismo

import (
	"bytes"
	"encoding/json"
	"math"
	"math/rand/v2"
	"os"
	"strings"
	"testing"
)

func TestOutsideDeterminismo(t *testing.T) {
	file := t.TempDir() + "/events.jsonl"
	os.Setenv("DETERMINISMO_SDK_LOCAL_OUTPUT", file)
	Always(RandomBelow(1) == 0, "the draw is zero", map[string]any{"n": 0})
	AlwaysGreaterThanOrEqualTo(3, 3, "three ties three", nil)
	SometimesAll([]NamedBool{{"a", true}, {"b", false}}, "a and b", nil)
	Event("started", nil)
	Optimize("backlog", map[string]any{"leader": "n1"}, 3, Maximize)
	Output(map[string]any{"custom": 1})
	BuggifyPause("anywhere")
	if Buggify("anywhere") {
		t.Fatal("buggify outside determinismo")
	}
	if Random() >= 1 || Decide("which", []string{"a", "b"}) > 1 {
		t.Fatal("randomness out of range")
	}
	generator := rand.New(Prng())
	if generator.IntN(10) >= 10 || rand.New(Source()).IntN(5) >= 5 {
		t.Fatal("generators out of range")
	}
	// Numbers JSON has no form for: the assertions stay (encoding/json refuses them, and each
	// was replaced by a determinismo_unencodable event), their operands strings.
	AlwaysLessThan(math.Inf(1), 100.0, "latency stays under 100 ms", nil)
	SometimesGreaterThan(math.Inf(1), 0.0, "a throughput above zero", nil)
	AlwaysGreaterThan(math.NaN(), 0.0, "a ratio above zero", nil)
	Always(true, "details with infinity", map[string]any{"latency": math.Inf(1)})
	Declare("sometimes", "declared in a test")
	var listed bytes.Buffer
	if err := CatalogWrite(&listed); err != nil || !strings.Contains(listed.String(), "declared in a test") {
		t.Fatalf("catalog: %q %v", listed.String(), err)
	}
	events, _ := os.ReadFile(file)
	for _, want := range []string{`"message":"the draw is zero"`, `"line":`, `"guidance"`, `"custom":1`, `"event":"started"`,
		`"optimize":{"bucket":{"leader":"n1"},"goal":"maximize","message":"backlog","value":3}`} {
		if !strings.Contains(string(events), want) {
			t.Fatalf("local output lacks %s:\n%s", want, events)
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(string(events)), "\n") {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			t.Fatalf("not JSON: %s (%v)", line, err)
		}
	}
	for _, want := range []string{`"left":"Infinity","right":100`, `"left":"NaN"`, `"message":"details with infinity"`,
		`"distance":-1.7976931348623157e+308`} {
		if !strings.Contains(string(events), want) {
			t.Fatalf("local output lacks %s:\n%s", want, events)
		}
	}
	if strings.Contains(string(events), "determinismo_unencodable") {
		t.Fatalf("an event was not encodable:\n%s", events)
	}
}

type ledger struct{}

func (*ledger) where() map[string]any { return callerLocation() }

func TestReceiverOf(t *testing.T) {
	for function, want := range map[string]string{
		"example.com/bank.(*Ledger).Audit":      "Ledger",
		"bank.Ledger.Audit":                     "Ledger",
		"bank.(*Ledger).Audit.func1":            "Ledger",
		"bank.(*Ledger).Audit.func1.2":          "Ledger",
		"bank.Ledger[...].Audit":                "Ledger",
		"bank.(*Ledger[...]).Audit.gowrap1":     "Ledger",
		"bank.audit.func1":                      "",
		"main.main":                             "",
		"example.com/x/v2/bank.(*Store).funcky": "Store",
	} {
		if got := receiverOf(function); got != want {
			t.Errorf("receiverOf(%q) = %q, want %q", function, got, want)
		}
	}
	// An assertion's location from a method: its class, the method's own name its function.
	if location := (&ledger{}).where(); location["class"] != "ledger" {
		t.Fatalf("a method's location lacks its class: %v", location)
	}
}

func TestRandomNear(t *testing.T) {
	seen := map[uint64]bool{}
	for range 2000 {
		value := RandomNear("test.batch", 64, 1000)
		if value > 1000 {
			t.Fatalf("value %d past max", value)
		}
		seen[value] = true
	}
	for _, edge := range []uint64{0, 1, 63, 64, 65, 128} {
		if !seen[edge] {
			t.Fatalf("edge %d never drawn", edge)
		}
	}
	if value := RandomNear("test.small", 64, 10); value > 10 {
		t.Fatalf("value %d past a max under the limit", value)
	}
}

func TestSwarmHash(t *testing.T) {
	// The Zig SDK's vectors: every SDK derives the same table.
	if got := SwarmHash(1, "cache.operation", 0, 2); got != 0xbf59ece8b9488041 {
		t.Fatalf("vector 1: %x", got)
	}
	if got := SwarmHash(42, "a", 7, 16); got != 0xf5452f6a537dff80 {
		t.Fatalf("vector 2: %x", got)
	}
	if index := SwarmIndex("cache.operation", 3); index >= 3 {
		t.Fatalf("index %d", index)
	}
}
