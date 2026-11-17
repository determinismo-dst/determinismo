// SPDX-License-Identifier: MIT

// Package determinismo is determinismo's SDK for Go: assertions, events and platform randomness.
//
// Inside determinismo everything goes through /dev/determinismo: events are recorded with their
// moment, and every random value is a decision the platform can steer and replay. Outside it (local
// runs) randomness comes from the OS and events go to the file DETERMINISMO_SDK_LOCAL_OUTPUT (or
// Antithesis's ANTITHESIS_SDK_LOCAL_OUTPUT) names, one JSON object a line, else nowhere (Antithesis's
// default: assertions evaluated, nothing written). Built
// with the tag determinismo_off, every call is a no-op (randomness from the OS).
//
//	account := determinismo.RandomBelow(10)
//	determinismo.Always(total == 1000, "total balance is conserved", map[string]any{"total": total})
//
// The assertion catalog: Go has no hook to announce assertions as code loads, so
// cmd/determinismo-catalog (`go generate`) writes each package's: an init that declares every
// assertion whose message is a literal, before it runs; CatalogAssertions lists them.
//
// The same API as the other SDKs (docs/SDKS.md), in Go's names; Antithesis's Go SDK's names
// (AlwaysGreaterThanOrEqualTo, SendEvent, GetRandom, NamedBool, Source) work too.
package determinismo

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const devicePath = "/dev/determinismo"

// MessageSizeMax is one event's or one randomness pull's size at most.
const MessageSizeMax = 4096 - 16

// faultsControl is faults.zig's control_path.
const faultsControl = "/opt/determinismo/faults-control"

var (
	deviceOnce sync.Once
	device     *os.File
	localOnce  sync.Once
	local      io.Writer
	emitLock   sync.Mutex
)

func deviceFile() *os.File {
	deviceOnce.Do(func() {
		if disabled {
			return
		}
		file, err := os.OpenFile(devicePath, os.O_RDWR, 0)
		if err == nil {
			device = file
		}
	})
	return device
}

// Inside says whether this process runs inside determinismo.
func Inside() bool {
	return deviceFile() != nil
}

func localOutput() io.Writer {
	localOnce.Do(func() {
		local = io.Discard
		path := os.Getenv("DETERMINISMO_SDK_LOCAL_OUTPUT")
		if path == "" {
			path = os.Getenv("ANTITHESIS_SDK_LOCAL_OUTPUT")
		}
		if path != "" {
			if file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644); err == nil {
				local = file
			}
		}
	})
	return local
}

// marshal writes a message with its kind's key first ({"event": ..., "details": ...}, as
// docs/SDKS.md has it): encoding/json sorts a map's keys, which put "details" first.
func marshal(message map[string]any) ([]byte, error) {
	details, ok := message["details"]
	if !ok || len(message) != 2 {
		return json.Marshal(message)
	}
	for key, value := range message {
		if key == "details" {
			continue
		}
		head, err := json.Marshal(map[string]any{key: value})
		if err != nil {
			return nil, err
		}
		tail, err := json.Marshal(details)
		if err != nil {
			return nil, err
		}
		data := append(head[:len(head)-1], `,"details":`...)
		return append(append(data, tail...), '}'), nil
	}
	return json.Marshal(message)
}

func emit(message map[string]any) {
	if disabled {
		return
	}
	data, err := marshal(message)
	if assertion, ok := message["assert"].(map[string]any); ok && err != nil {
		// Details encoding/json refuses (an infinite number, NaN): their text, a string, rather
		// than no assertion at all (the Zig SDK's "<details not JSON>").
		assertion["details"] = fmt.Sprintf("<details not JSON> %v", assertion["details"])
		data, err = marshal(message)
	}
	if err != nil {
		data, _ = json.Marshal(map[string]any{"event": "determinismo_unencodable", "details": map[string]any{"error": err.Error()}})
	}
	file := deviceFile()
	if file == nil {
		emitLock.Lock()
		defer emitLock.Unlock()
		localOutput().Write(append(data, '\n'))
		return
	}
	if len(data) > MessageSizeMax {
		// The assertion must not be lost, nor all its details: their JSON text, cut to what
		// fits, as a string (the Zig SDK's "<details cut>"; replaced whole, a failure said
		// nothing).
		if assertion, ok := message["assert"].(map[string]any); ok {
			text, _ := json.Marshal(assertion["details"])
			assertion["details"] = ""
			bare, _ := marshal(message)
			assertion["details"] = detailsCut(string(text), MessageSizeMax-len(bare)-64)
			data, _ = marshal(message)
		}
		if len(data) > MessageSizeMax {
			data = data[:MessageSizeMax]
		}
	}
	file.Write(data) // One write, one event.
}

// Output emits any JSON object as an event of its own (the protocol's raw form: docs/SDKS.md).
func Output(object map[string]any) {
	emit(object)
}

// Randomness -----------------------------------------------------------------------------------

// RandomBytes fills buffer with random bytes: a platform decision inside determinismo.
func RandomBytes(buffer []byte) {
	if len(buffer) == 0 || len(buffer) > MessageSizeMax {
		panic(fmt.Sprintf("determinismo: RandomBytes of %d bytes", len(buffer)))
	}
	file := deviceFile()
	if file == nil {
		if _, err := rand.Read(buffer); err != nil {
			panic(err)
		}
		return
	}
	read, err := file.Read(buffer)
	if err != nil || read != len(buffer) {
		panic(fmt.Sprintf("determinismo: the platform gave %d of %d bytes (%v)", read, len(buffer), err))
	}
}

// RandomU64 is a random 64-bit integer.
func RandomU64() uint64 {
	var bytes [8]byte
	RandomBytes(bytes[:])
	return binary.LittleEndian.Uint64(bytes[:])
}

// GetRandom is Antithesis's name for RandomU64.
func GetRandom() uint64 { return RandomU64() }

// RandomBelow is a uniformly random integer in [0, count).
func RandomBelow(count uint64) uint64 {
	if count == 0 {
		panic("determinismo: RandomBelow(0)")
	}
	return RandomU64() % count
}

// RandomChoice is one of items, at random; the zero value when there is none.
func RandomChoice[T any](items []T) T {
	var zero T
	if len(items) == 0 {
		return zero
	}
	return items[RandomBelow(uint64(len(items)))]
}

// Random is a float in [0, 1) from 53 random bits.
func Random() float64 {
	return float64(RandomU64()>>11) / (1 << 53)
}

// PlatformSource draws from the platform, one decision a draw: a math/rand/v2 Source
// (rand.New(determinismo.Source())).
type PlatformSource struct{}

// Uint64 is a platform decision.
func (PlatformSource) Uint64() uint64 { return RandomU64() }

// Source is Antithesis's name for a PlatformSource.
func Source() PlatformSource { return PlatformSource{} }

// Rng is a generator whose every draw is a platform decision (see Source); for hot loops, Prng.
func Rng() PlatformSource { return PlatformSource{} }

// SplitMix64 is a generator the platform seeds once: draws cost nothing, and replay with the
// seed. A math/rand/v2 Source too.
type SplitMix64 struct{ state uint64 }

// Prng is a SplitMix64 the platform seeds.
func Prng() *SplitMix64 { return &SplitMix64{state: RandomU64()} }

// Uint64 is the next draw.
func (generator *SplitMix64) Uint64() uint64 {
	generator.state += 0x9e3779b97f4a7c15
	z := generator.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// Labeled decisions: the platform's strategies see the name and the options -------------------

// Decide is a named decision among options (which fault, which account, which node): the index
// chosen, a platform decision announced with the options' names.
func Decide(name string, options []string) int {
	if len(options) == 0 {
		panic("determinismo: Decide without options")
	}
	if Inside() {
		emit(map[string]any{"decision": map[string]any{"name": name, "options": options}})
	}
	return int(RandomBelow(uint64(len(options))))
}

// RandomBelowNamed is RandomBelow, named for strategies ("retry.jitter_ms").
func RandomBelowNamed(name string, count uint64) uint64 {
	if Inside() {
		emit(map[string]any{"decision": map[string]any{"name": name, "range": count}})
	}
	return RandomBelow(count)
}

var nearEdges = []string{"zero", "one", "limit-1", "limit", "limit+1", "twice"}

// RandomNear is a value up to max drawn around a limit the workload declares (a batch size, a
// buffer, a threshold): half the time uniform, else one of the limit's edges, where bugs gather
// and uniform draws seldom land: 0, 1, limit - 1, limit, limit + 1 or twice it (each kept within
// max). Named decisions ("<name>.near", then name), as the Zig SDK's random_near.
func RandomNear(name string, limit, max uint64) uint64 {
	if max == 0 {
		panic("determinismo: RandomNear with max 0")
	}
	if RandomBelowNamed(name+".near", 2) == 0 {
		if max == math.MaxUint64 {
			return RandomBelowNamed(name, max)
		}
		return RandomBelowNamed(name, max+1)
	}
	var value uint64
	switch Decide(name, nearEdges) {
	case 0:
		value = 0
	case 1:
		value = 1
	case 2:
		if limit > 0 {
			value = limit - 1
		}
	case 3:
		value = limit
	case 4:
		value = limit
		if limit < math.MaxUint64 {
			value = limit + 1
		}
	default:
		value = math.MaxUint64
		if limit <= math.MaxUint64/2 {
			value = limit * 2
		}
	}
	if value > max {
		return max
	}
	return value
}

// Swarm testing over a workload's operations: the Zig SDK's swarm_index (sdk/zig/
// determinismo.zig), the same table from the same seed (FNV-1a and SplitMix64), so drivers in
// any language agree on a timeline's mix.

const swarmSeedPath = "/opt/determinismo/swarm-seed"

var (
	swarmMu         sync.Mutex
	swarmSeedCached *uint64
	swarmRuns       = map[string][2]uint64{} // name -> {stretch, answer}
)

func swarmMix(value uint64) uint64 {
	z := value + 0x9e3779b97f4a7c15
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// SwarmHash is the table's draws: FNV-1a of the name, mixed with the seed, stretch and what by
// SplitMix64, the same in every SDK.
func SwarmHash(seed uint64, name string, stretch, what uint64) uint64 {
	nameHash := uint64(0xcbf29ce484222325)
	for i := 0; i < len(name); i++ {
		nameHash = (nameHash ^ uint64(name[i])) * 0x100000001b3
	}
	return swarmMix(swarmMix(swarmMix(seed^nameHash)^stretch) ^ what)
}

func swarmSeed() (uint64, bool) {
	if swarmSeedCached != nil {
		return *swarmSeedCached, true
	}
	text, err := os.ReadFile(swarmSeedPath)
	if err != nil {
		return 0, false
	}
	seed, err := strconv.ParseUint(strings.TrimSpace(string(text)), 10, 64)
	if err != nil {
		return 0, false
	}
	swarmSeedCached = &seed
	return seed, true
}

// SwarmIndex is an index below count (64 at most) by swarm testing: among the options this
// timeline keeps for the name, weighted and repeated in runs, the table changing with stretches
// of virtual time. Plain uniform outside determinismo, before the drivers, or with --no-swarm.
func SwarmIndex(name string, count uint64) uint64 {
	if count == 0 || count > 64 {
		panic("determinismo.SwarmIndex: 1 to 64 options")
	}
	label := "swarm." + name
	swarmMu.Lock()
	defer swarmMu.Unlock()
	seed, ok := swarmSeed()
	if !ok {
		return RandomBelowNamed(label, count)
	}
	stretch := monotonicMs() / (10_000 + SwarmHash(seed, name, 0, 1)%110_001)
	eighths := 1 + SwarmHash(seed, name, stretch, 2)%7
	mean := [4]uint64{1, 4, 16, 64}[SwarmHash(seed, name, stretch, 3)%4]
	weights := make([]uint64, count)
	var kept, total uint64
	for i := uint64(0); i < count; i++ {
		drawn := SwarmHash(seed, name, stretch, 16+i)
		if drawn%8 >= eighths {
			continue
		}
		weights[i] = 1 << ((drawn >> 32) % 8)
		kept |= 1 << i
	}
	if kept == 0 {
		i := SwarmHash(seed, name, stretch, 4) % count
		weights[i] = 1
		kept = 1 << i
	}
	for _, weight := range weights {
		total += weight
	}
	run, ran := swarmRuns[name]
	if ran && run[0] == stretch && mean > 1 && RandomBelowNamed(label+" run", mean) != 0 {
		return run[1]
	}
	pick := RandomBelowNamed(label, total)
	answer := uint64(0)
	for i, weight := range weights {
		if pick < weight {
			answer = uint64(i)
			break
		}
		pick -= weight
	}
	if !ran || run[0] != stretch {
		Event("swarm", map[string]any{"name": name, "stretch": stretch, "kept": kept, "mean": mean})
	}
	swarmRuns[name] = [2]uint64{stretch, answer}
	return answer
}

// SwarmChoice is one of the items by swarm testing (SwarmIndex), where RandomChoice drew one
// uniformly.
func SwarmChoice[T any](name string, items []T) T {
	return items[SwarmIndex(name, uint64(len(items)))]
}

type buggifyPoint struct {
	generator *SplitMix64 // nil when inactive
	until     time.Time
}

var (
	buggifyLock   sync.Mutex
	buggifyPoints = map[string]*buggifyPoint{}
)

const buggifyPeriod = 2 * time.Second

func buggifyDraw(name string) (uint64, bool) {
	if !Inside() {
		return 0, false
	}
	now := time.Now() // Virtual time inside determinismo.
	buggifyLock.Lock()
	defer buggifyLock.Unlock()
	point := buggifyPoints[name]
	if point == nil || !now.Before(point.until) {
		var generator *SplitMix64
		if RandomBelowNamed("buggify "+name, 4) == 0 {
			generator = Prng()
		}
		point = &buggifyPoint{generator: generator, until: now.Add(buggifyPeriod)}
		buggifyPoints[name] = point
	}
	if point.generator == nil {
		return 0, false
	}
	return point.generator.Uint64(), true
}

// Buggify is a buggify point (FoundationDB's BUGGIFY): inside determinismo, a point is active one
// stretch of two seconds (virtual time) in four, a named decision ("buggify <name>") at the
// stretch's first evaluation; while active, it is true one evaluation in four, drawn from its own
// generator seeded by the platform for the stretch. Outside determinismo, always false. Where it
// is true, take a rare path the real system can take too (a pause, a retry), never one it cannot.
func Buggify(name string) bool {
	value, active := buggifyDraw(name)
	return active && value%4 == 0
}

// BuggifyPause pauses up to 9 ms one evaluation in 32 while the point is active (rarer than
// Buggify: pause points sit on hot paths).
func BuggifyPause(name string) {
	value, active := buggifyDraw(name)
	if !active || value%32 != 0 {
		return
	}
	if ms := (value >> 8) % 10; ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
}

// Assertions -----------------------------------------------------------------------------------

var (
	assertionLock sync.Mutex
	firstOnly     bool
	seen          = map[string]bool{}
	located       = map[string]bool{}
	best          = map[string]float64{}
)

// SetAssertionEvents chooses which evaluations become events: every one (false, the default:
// queries see each), or, as Antithesis's SDKs do, each assertion's first pass and first failure in
// this process (true: for hot paths, the same verdict with far fewer events). Set it once.
func SetAssertionEvents(firstPassFirstFailure bool) {
	assertionLock.Lock()
	defer assertionLock.Unlock()
	firstOnly = firstPassFirstFailure
}

func assertAt(kind string, condition bool, message string, details map[string]any) {
	if message == "" {
		panic("determinismo: an assertion needs a message")
	}
	assertionLock.Lock()
	key := fmt.Sprintf("%t\x00%s", condition, message)
	if firstOnly && seen[key] {
		assertionLock.Unlock()
		return
	}
	seen[key] = true
	withLocation := !located[message] // Its location once per process: the platform keeps it.
	located[message] = true
	assertionLock.Unlock()
	if details == nil {
		details = map[string]any{}
	}
	body := map[string]any{"type": kind, "message": message, "condition": condition, "details": details}
	if withLocation {
		if location := callerLocation(); location != nil {
			body["location"] = location
		}
	}
	emit(map[string]any{"assert": body})
}

// callerLocation is where the SDK was called from: the first frame outside this file.
func callerLocation() map[string]any {
	for skip := 1; skip < 12; skip++ {
		pc, file, line, ok := runtime.Caller(skip)
		if !ok {
			break
		}
		if strings.HasSuffix(file, "/determinismo.go") && strings.Contains(file, "determinismo/sdk/go") {
			continue
		}
		function := ""
		if fn := runtime.FuncForPC(pc); fn != nil {
			function = fn.Name()
		}
		location := map[string]any{"file": file, "line": line, "function": function}
		if class := receiverOf(function); class != "" {
			location["class"] = class
		}
		return location
	}
	return nil
}

// receiverOf is the type a method belongs to, from its function's name (runtime.FuncForPC's):
// "example.com/bank.(*Ledger).Audit" and "bank.Ledger.Audit.func1" are Ledger's;
// "bank.audit.func1" and "main.main" are no type's.
func receiverOf(function string) string {
	name := function[strings.LastIndexByte(function, '/')+1:]
	dot := strings.IndexByte(name, '.')
	if dot < 0 {
		return ""
	}
	// After the package: Type.Method, (*Type).Method, Type[...].Method, then closures (funcN).
	rest := strings.Split(name[dot+1:], ".")
	for len(rest) > 0 && closure(rest[len(rest)-1]) {
		rest = rest[:len(rest)-1]
	}
	if len(rest) < 2 {
		return ""
	}
	class := strings.TrimSuffix(strings.TrimPrefix(rest[0], "(*"), ")")
	if bracket := strings.IndexByte(class, '['); bracket >= 0 {
		class = class[:bracket]
	}
	return class
}

// closure: a name's segment for a function literal (func1, gowrap2, or 2 in func1.2).
func closure(segment string) bool {
	digits := strings.TrimPrefix(strings.TrimPrefix(segment, "func"), "gowrap")
	return digits != "" && strings.Trim(digits, "0123456789") == ""
}

// Always: the condition holds every time this runs, and this runs in some timeline.
func Always(condition bool, message string, details map[string]any) {
	assertAt("always", condition, message, details)
}

// AlwaysOrUnreachable: the condition holds every time this runs (never running is fine).
func AlwaysOrUnreachable(condition bool, message string, details map[string]any) {
	assertAt("always_or_unreachable", condition, message, details)
}

// Sometimes: the condition holds at least once in some timeline.
func Sometimes(condition bool, message string, details map[string]any) {
	assertAt("sometimes", condition, message, details)
}

// Reachable: this runs in some timeline.
func Reachable(message string, details map[string]any) {
	assertAt("reachable", true, message, details)
}

// Unreachable: this never runs.
func Unreachable(message string, details map[string]any) {
	assertAt("unreachable", true, message, details)
}

// Guidance assertions: the compared values in the details, and a guidance event telling
// strategies how far the timeline is from the interesting outcome (an always violated, a
// sometimes true): distance, lower is closer, 0 or less is there.

func guidance(message string, distance float64) {
	// NaN is nowhere; an infinite distance (an infinite operand) is the largest JSON number:
	// encoding/json refuses infinity, and the guidance was an unencodable event.
	if math.IsNaN(distance) {
		return
	}
	distance = math.Max(-math.MaxFloat64, math.Min(math.MaxFloat64, distance))
	assertionLock.Lock()
	known, ok := best[message]
	if ok && distance >= known {
		assertionLock.Unlock()
		return // Only improvements.
	}
	best[message] = distance
	assertionLock.Unlock()
	emit(map[string]any{"guidance": map[string]any{"message": message, "distance": distance}})
}

// Goal is an objective's direction (Optimize).
type Goal string

const (
	Maximize Goal = "maximize"
	Minimize Goal = "minimize"
)

// Optimize is an objective for exploration (Antithesis's "Optimizing our way through Metroid"):
// bucket's strings and booleans split states into buckets (a leader, a phase), explored evenly,
// each keeping the state with the best value by goal; the tree returns there and goes further
// from it.
func Optimize(message string, bucket map[string]any, value float64, goal Goal) {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return
	}
	if bucket == nil {
		bucket = map[string]any{}
	}
	emit(map[string]any{"optimize": map[string]any{"message": message, "bucket": bucket, "value": value, "goal": goal}})
}

// Number is what the guidance comparisons take.
type Number interface {
	~int | ~int8 | ~int16 | ~int32 | ~int64 | ~uint | ~uint8 | ~uint16 | ~uint32 | ~uint64 | ~uintptr | ~float32 | ~float64
}

// operand is a comparison's operand as JSON. JSON has no infinity or NaN (encoding/json refuses
// them: the whole assertion was an unencodable event), so those are the strings "Infinity",
// "-Infinity" and "NaN", as every SDK of ours sends them.
func operand[T Number](value T) any {
	number := float64(value)
	switch {
	case math.IsNaN(number):
		return "NaN"
	case math.IsInf(number, 1):
		return "Infinity"
	case math.IsInf(number, -1):
		return "-Infinity"
	}
	return value
}

func compare[T Number](kind string, holds bool, margin float64, left, right T, message string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	assertAt(kind, holds, message, map[string]any{"left": operand(left), "right": operand(right), "details": details})
	if kind == "always" {
		guidance(message, margin)
	} else {
		guidance(message, -margin)
	}
}

func AlwaysGreaterThan[T Number](left, right T, message string, details map[string]any) {
	compare("always", left > right, float64(left)-float64(right), left, right, message, details)
}

func AlwaysGreaterThanOrEqual[T Number](left, right T, message string, details map[string]any) {
	compare("always", left >= right, float64(left)-float64(right), left, right, message, details)
}

func AlwaysLessThan[T Number](left, right T, message string, details map[string]any) {
	compare("always", left < right, float64(right)-float64(left), left, right, message, details)
}

func AlwaysLessThanOrEqual[T Number](left, right T, message string, details map[string]any) {
	compare("always", left <= right, float64(right)-float64(left), left, right, message, details)
}

func SometimesGreaterThan[T Number](left, right T, message string, details map[string]any) {
	compare("sometimes", left > right, float64(left)-float64(right), left, right, message, details)
}

func SometimesGreaterThanOrEqual[T Number](left, right T, message string, details map[string]any) {
	compare("sometimes", left >= right, float64(left)-float64(right), left, right, message, details)
}

func SometimesLessThan[T Number](left, right T, message string, details map[string]any) {
	compare("sometimes", left < right, float64(right)-float64(left), left, right, message, details)
}

func SometimesLessThanOrEqual[T Number](left, right T, message string, details map[string]any) {
	compare("sometimes", left <= right, float64(right)-float64(left), left, right, message, details)
}

// Antithesis's names.

func AlwaysGreaterThanOrEqualTo[T Number](left, right T, message string, details map[string]any) {
	AlwaysGreaterThanOrEqual(left, right, message, details)
}

func AlwaysLessThanOrEqualTo[T Number](left, right T, message string, details map[string]any) {
	AlwaysLessThanOrEqual(left, right, message, details)
}

func SometimesGreaterThanOrEqualTo[T Number](left, right T, message string, details map[string]any) {
	SometimesGreaterThanOrEqual(left, right, message, details)
}

func SometimesLessThanOrEqualTo[T Number](left, right T, message string, details map[string]any) {
	SometimesLessThanOrEqual(left, right, message, details)
}

// NamedBool is a named condition (Antithesis's Go SDK's).
type NamedBool struct {
	First  string `json:"first"`
	Second bool   `json:"second"`
}

func named(conditions []NamedBool) (map[string]any, int) {
	held := 0
	values := map[string]any{}
	for _, condition := range conditions {
		values[condition.First] = condition.Second
		if condition.Second {
			held++
		}
	}
	return values, held
}

// AlwaysSome: at least one of the named conditions holds, every time.
func AlwaysSome(conditions []NamedBool, message string, details map[string]any) {
	values, held := named(conditions)
	assertAt("always", held > 0, message, map[string]any{"conditions": values, "details": details})
	guidance(message, float64(held))
}

// SometimesAll: all the named conditions hold together, at least once.
func SometimesAll(conditions []NamedBool, message string, details map[string]any) {
	values, held := named(conditions)
	assertAt("sometimes", held == len(conditions), message, map[string]any{"conditions": values, "details": details})
	guidance(message, float64(len(conditions)-held))
}

// The catalog -----------------------------------------------------------------------------------

// CatalogEntry is one assertion the program declares.
type CatalogEntry struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

var (
	catalogLock sync.Mutex
	declared    = map[CatalogEntry]bool{}
)

// Declare announces an assertion before it runs: one never reached is judged too. The catalog
// cmd/determinismo-catalog writes calls it for every assertion with a literal message.
func Declare(kind, message string) {
	entry := CatalogEntry{Kind: kind, Message: message}
	catalogLock.Lock()
	known := declared[entry]
	declared[entry] = true
	catalogLock.Unlock()
	if known || !Inside() {
		return // Outside determinismo, listed but not announced.
	}
	emit(map[string]any{"assert": map[string]any{"type": kind, "message": message, "hit": false}})
}

// CatalogAssertions lists the assertions declared so far.
func CatalogAssertions() []CatalogEntry {
	catalogLock.Lock()
	defer catalogLock.Unlock()
	entries := make([]CatalogEntry, 0, len(declared))
	for entry := range declared {
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(a, b int) bool {
		if entries[a].Kind != entries[b].Kind {
			return entries[a].Kind < entries[b].Kind
		}
		return entries[a].Message < entries[b].Message
	})
	return entries
}

// CatalogWrite writes the catalog, one JSON object a line, to out: for review or CI.
func CatalogWrite(out io.Writer) error {
	for _, entry := range CatalogAssertions() {
		line, _ := json.Marshal(entry)
		if _, err := out.Write(append(line, '\n')); err != nil {
			return err
		}
	}
	return nil
}

// Lifecycle and events ----------------------------------------------------------------------------

// SetupComplete: the system is ready; the platform snapshots here and starts exploring.
func SetupComplete(details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	emit(map[string]any{"lifecycle": "setup_complete", "details": details})
}

// Event is a structured event: {"event": name, "details": details}.
func Event(name string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	emit(map[string]any{"event": name, "details": details})
}

// SendEvent is Antithesis's name for Event.
func SendEvent(name string, details map[string]any) { Event(name, details) }

// The fault injector ------------------------------------------------------------------------------

func faults(message []byte) {
	fifo, err := os.OpenFile(faultsControl, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return // No injector running.
	}
	defer fifo.Close()
	fifo.Write(message) // Atomic: under PIPE_BUF.
}

// CrashPoint marks a moment worth a crash (CrashTuner's points, by hand: the node just changed its
// view of the cluster, a record is half written), as the Zig SDK's crash_point: inside
// determinismo and in a node, a point is armed one two-second stretch in eight (a named decision,
// "crash point <name>"), and its first evaluation then asks the fault injector to crash this node
// now and waits for it up to half a second. The injector grants it as one of the node's crash
// faults the swarm keeps (a kill or a power loss), outside quiet periods; where it would refuse
// (its published state), the goroutine goes on at once. Nothing elsewhere.
func CrashPoint(name string) {
	if !Inside() {
		return
	}
	node := os.Getenv("DETERMINISMO_NODE")
	if node == "" {
		return // The runner's processes crash nothing.
	}
	now := monotonicNs()
	crashPointLock.Lock()
	point := crashPoints[name]
	if point == nil || now >= point.until {
		point = &crashPointState{armed: RandomBelowNamed("crash point "+name, 8) == 0, until: now + uint64(buggifyPeriod)}
		crashPoints[name] = point
	}
	armed := point.armed
	point.armed = false // Once a stretch.
	crashPointLock.Unlock()
	if !armed || !crashPointOpen(node, now) {
		return
	}
	body := []byte(fmt.Sprintf("%d %s\npoint %s", now, node, name))
	if len(body) > 4000 {
		body = body[:4000]
	}
	message := make([]byte, 8, 8+len(body))
	binary.LittleEndian.PutUint64(message, crashPointFlag|uint64(len(body)))
	faults(append(message, body...))
	for monotonicNs()-now < crashPointWaitNs {
		time.Sleep(5 * time.Millisecond)
	}
}

type crashPointState struct {
	armed bool
	until uint64
}

var (
	crashPointLock sync.Mutex
	crashPoints    = map[string]*crashPointState{}
)

// faults.zig's crash_point_flag and crash_points_path; how old a request it grants.
const (
	crashPointFlag   = uint64(1) << 59
	crashPointsState = "/opt/determinismo/crash-points"
	crashPointWaitNs = 500_000_000
)

// crashPointOpen says whether the injector may grant node a crash point now: the end of a quiet
// period, then the nodes whose crash faults the swarm keeps, a line each.
func crashPointOpen(node string, now uint64) bool {
	text, err := os.ReadFile(crashPointsState)
	if err != nil {
		return false
	}
	lines := strings.Split(string(text), "\n")
	quietUntil, err := strconv.ParseUint(lines[0], 10, 64)
	if err != nil || now < quietUntil {
		return false
	}
	for _, line := range lines[1:] {
		if line == node {
			return true
		}
	}
	return false
}

// StopFaults is a quiet period (Antithesis's ANTITHESIS_STOP_FAULTS): faults stop for seconds,
// except clock skips; 0 ends it. Only while the fault injector runs.
func StopFaults(seconds float64) {
	if seconds < 0 {
		seconds = 0
	}
	var message [8]byte
	binary.LittleEndian.PutUint64(message[:], uint64(seconds*1e9))
	faults(message[:])
}

// FaultAim aims the fault injector at node from now on, until another call ("" for none): half
// its faults involve it, each a decision strategies see and replays repeat (a primary, a leader).
func FaultAim(node string) {
	name := []byte(node)
	if len(name) > 32 {
		name = name[:32]
	}
	message := make([]byte, 8, 8+len(name))
	binary.LittleEndian.PutUint64(message, (1<<61)|uint64(len(name)))
	faults(append(message, name...))
}

// Fault is a fault now, from the scenario: Fault(map[string]any{"kind": "pause", "node": "db",
// "duration_ms": 2000}). Applied, logged and undone like a drawn one (guest/runtime/faults.zig
// lists the kinds). Only while the fault injector runs.
func Fault(request map[string]any) {
	body, err := json.Marshal(request)
	if err != nil || len(body)+8 > 4096 {
		panic("determinismo: a fault request is a JSON object of at most 4088 bytes")
	}
	message := make([]byte, 8, 8+len(body))
	binary.LittleEndian.PutUint64(message, (1<<63)|uint64(len(body)))
	faults(append(message, body...))
}

// detailsCut: "<details cut> " and as much of text as fits in room bytes once JSON-encoded, whole
// runes only.
func detailsCut(text string, room int) string {
	cut := "<details cut> " + text
	for len(cut) > 0 {
		encoded, _ := json.Marshal(cut)
		if len(encoded) <= room {
			return cut
		}
		over := (len(encoded) - room + 1) / 2
		if over < 1 {
			over = 1
		}
		end := len(cut) - over
		if end < 0 {
			end = 0
		}
		for end > 0 && !utf8.RuneStart(cut[end]) {
			end--
		}
		cut = cut[:end]
	}
	return cut
}
