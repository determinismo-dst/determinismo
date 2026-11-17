;; SPDX-License-Identifier: MIT
(ns repl-test
  "The e2e repl check's program (tools/e2e.zig, check_repl): a client node, a JVM with nREPL, a
  peer node beside it, a scenario that only waits. What runs in it is the REPL's: the check
  connects through a session, writes a racy service and its workload there, runs them, reads the
  verdict over nREPL, controls the peer through the runner (det_runner) and forks the machine
  from the REPL. Its mechanics scenario has a fault kind of its own (e2e `mechanics`)."
  (:require [determinismo.workload :as w]))

(def peers ["peer" "peer-2"])

(defn rolling-restart
  "A fault kind of this program's (:custom-faults), a mechanic the platform lacks: the peers
  killed and started again one at a time, their order and the pauses drawn by the platform."
  [_]
  (doseq [node (w/shuffle peers)]
    (w/node! :kill node)
    (w/sleep-ms (inc (w/random-below 2000)))
    (w/node! :start node)))

(defn restarts
  "Asks the fault injector for the program's fault (it also picks it on its own)."
  [_]
  (w/fault {:kind "custom" :node "client" :program "/opt/workload/run fault rolling-restart"})
  (w/sleep-ms 10000))

(defn peers-answer
  "Once faults stop: every peer answers, within 30 s (a restart under way when they stopped
  finishes first)."
  [_]
  (doseq [node peers]
    (let [answered (loop [tries 60]
                     (let [status (:status (w/node-exec node "true"))]
                       (cond (zero? status) true
                             (zero? tries) false
                             :else (do (w/sleep-ms 500) (recur (dec tries))))))]
      (w/always answered "every peer answers after the restarts" {:node node}))))

(def program
  {:profiles [{:name "default"
               ;; The client's command prepares the program (its namespaces compiled) then
               ;; serves its REPL, ready once it listens: both before the setup's snapshot, so
               ;; every command starts prepared and every session finds the REPL warm.
               :nodes [[:client {:build {:context "." :dockerfile "tests/repl/Dockerfile"}
                                 :command ["sh" "-c" "/opt/workload/run prepare && exec /opt/workload/run nrepl 7888 0.0.0.0"]
                                 :ready {:tcp 7888 :timeout-s 180}
                                 :faults {:pause false :isolate false :partition false :sync-stall false
                                          :disk-lost-writes false :degrade false :runner-links false
                                          :throttle false :process-pause false :interleave false}}]
                       [:peer {:build {:context "." :dockerfile "tests/repl/Dockerfile"}
                               :command ["sleep" "infinity"]}]
                       [:peer-2 {:build {:context "." :dockerfile "tests/repl/Dockerfile"}
                                 :command ["sleep" "infinity"]}]]}]
   :node :client
   :program "/opt/workload/run"
   :custom-faults {"rolling-restart" rolling-restart}
   :scenarios [{:name "repl" :faults false
                :commands [(w/singleton-driver "wait" (fn [_] (w/sleep-ms 30000)))]}
               {:name "mechanics"
                :commands [(w/singleton-driver "restarts" restarts)
                           (w/eventually "peers answer" peers-answer)]}]})

(defn -main [& arguments]
  (w/main program arguments))
