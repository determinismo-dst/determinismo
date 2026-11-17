;; SPDX-License-Identifier: MIT
;; libdeterminismo for jank, as a -sys package (jank's book, "Packaging a system library"): no
;; wrapper, only the library made available (jank-build.bb). The determinismo package wraps it.
(defproject org.determinismo/determinismo-sys "0.1.0"
  :description "Raw package for libdeterminismo, determinismo's SDK behind a C ABI."
  :license {:name "MIT"}
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]])
