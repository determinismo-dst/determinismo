// SPDX-License-Identifier: MIT
// The race of examples/race in JavaScript (Node.js worker threads over a SharedArrayBuffer): runs
// (racerun.js) again and again in this process, printing every run's counter (the same line each
// run: no hint for the explorer). A run where all 64 threads incremented the counter throws: the
// uncaught error ends the process (an unexpected exit). Coverage, and so thread pausing, covers
// raceworker.js alone.
"use strict";
const path = require("path");
const determinismo = require("./determinismo");
const racerun = require("./racerun");

determinismo.coverageStart({ paths: [path.join(__dirname, "raceworker.js")] });

(async () => {
  for (let runs = 1; ; runs++) {
    const counter = await racerun.run();
    if (counter === racerun.THREADS) throw new Error(`all ${racerun.THREADS} threads incremented the counter`);
    console.log(`run ${runs}: counter ${counter}`);
  }
})();
