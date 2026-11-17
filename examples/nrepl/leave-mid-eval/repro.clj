;; SPDX-License-Identifier: MIT
;; nREPL: a client leaving in the middle of an evaluation loses the evaluations another client
;; queued in the same session. A starts a 3 s eval in its session and disconnects; B connects
;; and evaluates :b in that session at once (queued behind A's). Expected: :b answered once A's
;; eval ends. Controls: A stays connected (B's eval answered), and B evaluates after A's eval ended.
(require '[nrepl.core :as nrepl] '[nrepl.server :as server] '[nrepl.transport :as t])

(defn attempt [srv leave? wait-ms]
  (let [port (:port srv)
        conn-a (nrepl/connect :port port)
        session (-> (nrepl/message (nrepl/client conn-a 5000) {:op "clone"}) first :new-session)]
    (t/send conn-a {:op "eval" :id "a" :session session :code "(do (Thread/sleep 3000) :a)"})
    (Thread/sleep 500)
    (when leave? (.close conn-a))
    (Thread/sleep wait-ms)
    (with-open [conn-b (nrepl/connect :port port)]
      (let [client (nrepl/client conn-b 10000)
            replies (doall (nrepl/message client {:op "eval" :id "b" :session session :code ":b"}))]
        (when-not leave? (.close conn-a))
        (cond (some :value replies) (some :value replies)
              (some #(some #{"done"} (:status %)) replies) (vec (distinct (mapcat :status replies)))
              :else :no-reply-within-10s)))))

(with-open [srv (server/start-server :port 0)]
  (println "A leaves, B queues at once:       " (vec (repeatedly 5 #(attempt srv true 0))))
  (println "A stays, B queues at once:        " (vec (repeatedly 5 #(attempt srv false 0))))
  (println "A leaves, B after A's eval ended: " (vec (repeatedly 5 #(attempt srv true 3500)))))
(shutdown-agents)
