// SPDX-License-Identifier: MIT
// One run of the race of examples/race, in JavaScript: 64 worker threads (raceworker.js) each
// increment the shared counter if it is still zero; resolves to the counter once all answered.
// The workers are a pool, made once (as a program keeps its workers): a Node.js isolate a thread
// took the guest about 7 s for 64, a run each time (a run of the pool takes milliseconds).
"use strict";
const { Worker } = require("worker_threads");
const path = require("path");

const THREADS = 64;
const shared = new SharedArrayBuffer(4);
const counter = new Int32Array(shared);
const workers = [];
let waiting = 0;
let done = null;

function pool() {
  const file = path.join(__dirname, "raceworker.js");
  for (let i = 0; i < THREADS; i++) {
    const worker = new Worker(file, { workerData: shared });
    worker.on("message", () => {
      waiting -= 1;
      if (waiting === 0) done(counter[0]);
    });
    workers.push(worker);
  }
}

function run() {
  if (workers.length === 0) pool();
  counter[0] = 0;
  waiting = THREADS;
  return new Promise((resolve) => {
    done = resolve;
    for (const worker of workers) worker.postMessage(0);
  });
}

module.exports = { run, THREADS };
