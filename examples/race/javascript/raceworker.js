// SPDX-License-Identifier: MIT
// A thread of the race (racerun.js): at each run's message, the check-then-act, on one line as in
// race.cpp. The only file under coverage: its positions are where thread pausing pauses the
// workers.
"use strict";
const { parentPort, workerData } = require("worker_threads");
const counter = new Int32Array(workerData);
parentPort.on("message", () => {
  if (counter[0] === 0) counter[0] = counter[0] + 1;
  parentPort.postMessage(0);
});
