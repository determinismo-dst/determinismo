// SPDX-License-Identifier: MIT
// The SDK's own checks, outside determinismo: node sdk/javascript/test.js
"use strict";
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const output = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "det-js-")), "events.jsonl");
process.env.DETERMINISMO_SDK_LOCAL_OUTPUT = output;
const det = require("./determinismo.js");

for (const [name, owner] of [
  ["Ledger.audit", "Ledger"],
  ["async Ledger.audit", "Ledger"],
  ["new Ledger", "Ledger"],
  ["Ledger.audit [as check]", "Ledger"],
  ["bank.Ledger.audit", "bank.Ledger"],
  ["audit", null],
  ["", null],
  ["Object.<anonymous>", null],
]) {
  assert.strictEqual(det._classOf(name), owner, name);
}

// An assertion from a method carries its class, from a constructor too.
class Ledger {
  constructor() {
    det.always(true, "a ledger was made", {});
  }
  audit() {
    det.always(true, "a ledger was audited", {});
  }
}
new Ledger().audit();
const events = fs.readFileSync(output, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const located = (message) => events.find((event) => event.assert && event.assert.message === message).assert.location;
assert.strictEqual(located("a ledger was audited").class, "Ledger");
assert.strictEqual(located("a ledger was made").class, "Ledger");
// An empty choice is undefined, as in Antithesis's SDKs (Go's zero value, Rust's None).
assert.strictEqual(det.randomChoice([]), undefined);
assert.strictEqual(det.rng().choice([]), undefined);
assert.ok(["a", "b"].includes(det.randomChoice(["a", "b"])));
// A node's coverage set scopes coverage and thread pausing (DETERMINISMO_COVERAGE's prefixes, "-"
// excluding): the SDK itself never, then the program's paths, then the set.
const set = det._coverageSet("/app/,-/app/vendor/,-");
assert.deepStrictEqual(set, { included: ["/app/"], excluded: ["/app/vendor/"] });
const sdkFile = "/app/determinismo.js";
assert.strictEqual(det._coveredBy("/app/race.js", sdkFile, null, set), true);
assert.strictEqual(det._coveredBy("/app/vendor/lib.js", sdkFile, null, set), false);
assert.strictEqual(det._coveredBy("/usr/lib/node.js", sdkFile, null, set), false);
assert.strictEqual(det._coveredBy(sdkFile, sdkFile, null, det._coverageSet("")), false);
assert.strictEqual(det._coveredBy("/app/race.js", sdkFile, ["/app/raceworker.js"], set), false);
assert.strictEqual(det._coveredBy("/srv/any.js", sdkFile, null, det._coverageSet("")), true);
console.log("javascript sdk: ok");
