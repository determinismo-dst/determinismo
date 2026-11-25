(defproject determinismo/viz "0.1-SNAPSHOT"
  :description "determinismo's data and the moment lab drawn with Dear ImGui, from a jank REPL: cards (jankifier/cards) with determinismo's own."
  :license {:name "MIT"}
  ;; jankifier/cards: `lein install` in its directory (it brings Dear ImGui's packages).
  :dependencies [[jankifier/cards "0.1.0-SNAPSHOT"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :build-dependencies [[org.jank-lang.commons/jank-build "2026.10-1"]]
  :source-paths ["src" "../clojure/src"]
  :main determinismo.viz.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
