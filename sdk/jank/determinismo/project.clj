;; SPDX-License-Identifier: MIT
;; determinismo from jank: decisions, events, assertions and faults (libdeterminismo, through
;; determinismo-sys), for jank programs and REPLs in determinismo's guest.
(defproject org.determinismo/determinismo "0.1.0"
  :description "determinismo's SDK for jank."
  :license {:name "MIT"}
  :dependencies [[org.determinismo/determinismo-sys "0.1.0"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware])
