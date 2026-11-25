;; SPDX-License-Identifier: MIT
;; What determinismo does from a REPL, asked of the REPL itself: every public function of
;; determinismo.api (runs, events, replays, a node's file at a moment, timelines from a moment,
;; analyses), determinismo.debug (a session held at a moment: the machine's registers and
;; memory, breakpoints, commands in the guest and its nodes, checkpoints), determinismo.lab (a
;; session's moment as a world: faults injected there, time on, a fault against the same moment
;; without it), determinismo.lean (a Lean replica's counterexample driven on a session) and
;; determinismo.quint (a timeline against a Quint spec), with its arguments and documentation. For a person at an
;; editor and for an agent at an nREPL alike; the visualization draws what each call answers.
;;
;;   (require '[determinismo.help :refer [help]])
;;   (help)                          ; every function, its arguments, its first line
;;   (help "moment")                 ; those whose name or documentation says it
;;   (help 'determinismo.api/fork)   ; one, its whole documentation
(ns determinismo.help
  (:require [clojure.string :as str]
            [determinismo.api]
            [determinismo.debug]
            [determinismo.lab]
            [determinismo.lean]
            [determinismo.quint]))

(def namespaces
  "The namespaces `help` reads."
  '[determinismo.api determinismo.debug determinismo.lab determinismo.lean determinismo.quint])

(defn- entries
  "Every public function of the namespaces: {:name :args :doc (its first line) :whole}."
  []
  (vec (for [space namespaces
             [named value] (sort-by (fn [[k _]] (str k)) (ns-publics space))
             :let [m (meta value)]
             :when (:arglists m)]
         {:name (str space "/" named)
          :args (str/join " " (map str (:arglists m)))
          :doc (first (str/split-lines (or (:doc m) "")))
          :whole (or (:doc m) "")})))

(defn help
  "What the REPL can do with determinismo: every function with its arguments and the first line
  of its documentation; with a string, those whose name or documentation holds it (any case);
  with a symbol (`'determinismo.api/fork`), that one with its whole documentation."
  ([] (mapv (fn [entry] (dissoc entry :whole)) (entries)))
  ([about]
   (if (symbol? about)
     (first (filter (fn [entry] (= (:name entry) (str about))) (entries)))
     (let [wanted (str/lower-case (str about))]
       (vec (for [entry (entries)
                  :when (str/includes? (str/lower-case (str (:name entry) " " (:whole entry))) wanted)]
              (dissoc entry :whole)))))))
