(defproject determinismo/viz "0.1-SNAPSHOT"
  :description "determinismo's data drawn with Dear ImGui, from a jank REPL."
  :license {:name "MIT"}
  :dependencies [[org.jank-lang.commons/imgui-sys "2026.10-1"]
                 [org.jank-lang.commons/imgui-glfw-sys "2026.10-1"]
                 [org.jank-lang.commons/imgui-opengl2-sys "2026.10-1"]
                 [org.jank-lang.commons/implot-sys "2026.10-1"]]
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :source-paths ["src" "../clojure/src"]
  :main determinismo.viz.main
  :profiles {:base {:jank {:target-dir "target/debug"
                           :optimization-level 0}}})
