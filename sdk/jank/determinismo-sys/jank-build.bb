;; SPDX-License-Identifier: MIT
;; Where libdeterminismo is: every node of determinismo's guest has it at /opt/determinismo/lib
;; (libdeterminismo.so and libdeterminismo.h, docs/SDKS.md); DETERMINISMO_LIBRARY_DIR for
;; another. Linked by its absolute path: jank's -ldeterminismo with the directory's -L did not
;; load it in jank 0.1's REPL (2026-11), the path does.
(let [directory (or (System/getenv "DETERMINISMO_LIBRARY_DIR") "/opt/determinismo/lib")]
  (println (str "jank-build::include-dir=" directory))
  (println (str "jank-build::link-library=" directory "/libdeterminismo.so"))
  (println "jank-build::rerun-if-env-changed=DETERMINISMO_LIBRARY_DIR"))        
