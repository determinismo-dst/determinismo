;; SPDX-License-Identifier: MIT
(ns determinismo.session
  "Sessions from Clojure, for any REPL that reaches serve: a run's timeline replayed to a moment
  and held there (or live), driven step by step. Each det: step is a function here: `wait`,
  `until`, `at`, `background`, `exec` and `node-exec`. The guest's own REPL is evaluated
  through its relay (`start-repl`, `eval`). The machine runs only during a step (live: also
  between them), and serve records each step with its moment, so a session is a script that
  replays.

    (require '[determinismo.session :as s])
    (def session (s/open \"http://127.0.0.1:7879\" 3 {:branch 0 :at-ms 3000}))
    (s/start-repl session :client 7888)   ; the program's nREPL server and its relay
    (s/eval session \"(+ 1 2)\")           ; => {:value \"3\" ...}
    (s/until session 5000 \"event=leader_elected\")
    (s/forks session)                     ; the futures of the guest's sdk.fork calls
    (s/end session)

  Inside the guest the REPL drives the platform itself: determinismo.workload's `fault`,
  `stop-faults`, `fork!`, `sleep-ms`, decisions and assertions."
  (:refer-clojure :exclude [eval])
  (:require [clojure.string :as string]
            [determinismo.json :as json])
  (:import (java.net URI)
           (java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers)
           (java.time Duration)
           (java.util Base64)))

(set! *warn-on-reflection* true)

(def ^:private client (delay (HttpClient/newHttpClient)))

(defn- request [serve path body]
  (let [builder (-> (HttpRequest/newBuilder (URI/create (str serve path)))
                    (.timeout (Duration/ofHours 1))
                    (.header "Content-Type" "application/json"))
        request (if body
                  (.build (.POST builder (HttpRequest$BodyPublishers/ofString (json/write-str body))))
                  (.build (.GET builder)))
        response (.send ^HttpClient @client request (HttpResponse$BodyHandlers/ofString))]
    (when (>= (.statusCode response) 400)
      (throw (ex-info (str "serve answered " (.statusCode response)) {:path path :body (.body response)})))
    (.body response)))

(defn- post [serve path body] (json/read-str (request serve path body)))

(defn- post-get [serve path] (json/read-str (request serve path nil)))

(defn open
  "A session on run `run`'s timeline `branch`, at the first event matching `until` (`rewind-ms`
  before it), or at `at-ms` of virtual time, held there, or with :live running on between
  steps. Its replay's output so far under :output; :timeline, the timeline it records in the
  run (the run's next number): queried, replayed and opened by another session as any."
  [serve run {:keys [branch at-ms until rewind-ms live exec fresh-seed] :or {branch 0}}]
  (let [reply (post serve (str "/runs/" run "/session")
                    (cond-> {:branch branch :live (boolean live)}
                      at-ms (assoc :at_vtime_ms at-ms)
                      until (assoc :until until)
                      rewind-ms (assoc :rewind_ms rewind-ms)
                      exec (assoc :exec exec)
                      fresh-seed (assoc :fresh_seed fresh-seed)))]
    (when (:done reply)
      (throw (ex-info "the replay ended before its moment" {:output (:output reply)})))
    {:serve serve :run run :id (:session reply) :timeline (:timeline reply) :output (:output reply) :repl (atom nil)}))

(defn step
  "One step: a command in the guest's runner, or a det: step. Its output once it is done."
  [{:keys [serve id]} command]
  (let [reply (post serve (str "/sessions/" id "/step") {:exec command})]
    (when (:done reply)
      (throw (ex-info "the session ended" {:output (:output reply)})))
    (:output reply)))

(defn steps
  "Several steps in order, in one request (as a composite step is, det:ask): a command made of
  steps costs one round trip. Each is recorded with its moment. Their output, all of it."
  [{:keys [serve id]} commands]
  (let [reply (post serve (str "/sessions/" id "/step") {:steps (vec commands)})]
    (when (:done reply)
      (throw (ex-info "the session ended" {:output (:output reply)})))
    (:output reply)))

(defn events
  "The guest's events in a step's output, as data."
  [output]
  (for [line (string/split-lines output)
        :when (string/starts-with? line "[guest @")]
    (json/read-str (subs line (+ 2 (string/index-of line "] "))))))

(defn exec "A shell command in the guest's runner." [session command] (step session command))

(defn node-exec
  "A command in a node, as `docker exec`."
  [session node & argv]
  (step session (string/join " " (list* "det-nodes exec" (name node) argv))))

(defn wait "The machine runs on for `ms` of virtual time." [session ms] (step session (str "det:wait " ms)))

(defn until
  "The machine runs on until an event matches `condition` (query.zig's), `ms` at most (0: no
  limit)."
  [session ms condition]
  (step session (str "det:until " ms " " condition)))

(defn at "The machine runs on to `vtime-ns`." [session vtime-ns] (step session (str "det:at " vtime-ns)))

(defn background
  "A command run beside the next steps (its output and end come as they come)."
  [session command]
  (step session (str "det:background " command)))

(defn forks
  "The guest's forks (sdk.fork): each one's run (its futures, a run of serve's as any other:
  `run`, `watch`), its state and verdict lines."
  [{:keys [serve id]}]
  (post serve (str "/sessions/" id "/forks") {}))

(defn end
  "The session ended: its timeline released. Its last output."
  [{:keys [serve id]}]
  (:output (post serve (str "/sessions/" id "/end") {})))

;; The guest's REPL ------------------------------------------------------------------------------

(defn- bencode [value]
  (cond
    (integer? value) (str "i" value "e")
    (string? value) (let [bytes (.getBytes ^String value "UTF-8")] (str (alength bytes) ":" value))
    (keyword? value) (bencode (name value))
    (map? value) (str "d" (apply str (for [[k v] (sort-by (comp name key) value)] (str (bencode (name k)) (bencode v)))) "e")
    (sequential? value) (str "l" (apply str (map bencode value)) "e")))

(defn- debencode
  "One bencoded value of `bytes` from `at`: [value next]."
  [^bytes bytes at]
  (let [head (char (aget bytes at))]
    (case head
      \i (let [end (loop [i at] (if (= (int \e) (aget bytes i)) i (recur (inc i))))]
           [(parse-long (String. bytes (int (inc at)) (int (- end at 1)) "UTF-8")) (inc end)])
      (\l \d) (loop [i (inc at) items []]
                (if (= (int \e) (aget bytes i))
                  [(if (= head \l) items (into {} (map vec (partition 2 items)))) (inc i)]
                  (let [[item next] (debencode bytes i)] (recur next (conj items item)))))
      (let [colon (loop [i at] (if (= (int \:) (aget bytes i)) i (recur (inc i))))
            size (parse-long (String. bytes (int at) (int (- colon at)) "UTF-8"))]
        [(String. bytes (int (inc colon)) (int size) "UTF-8") (+ colon 1 size)]))))

(defn- replies
  "The relay's replies in a step's output: its nrepl_reply events, parts put together."
  [output]
  (loop [events (filter #(= "nrepl_reply" (:event %)) (events output)) pending [] result []]
    (if-let [{{:keys [data last]} :details} (first events)]
      (let [pending (conj pending (.decode (Base64/getDecoder) ^String data))]
        (if last
          (let [bytes (byte-array (mapcat seq pending))]
            (recur (rest events) [] (conj result (first (debencode bytes 0)))))
          (recur (rest events) pending result)))
      result)))

(defn- ask
  "One nREPL message through the session's relay (a det:ask step): its replies."
  [session message]
  (let [{:keys [fifo]} @(:repl session)
        text (bencode message)
        bytes (.getBytes ^String text "UTF-8")
        parts (for [at (range 0 (alength bytes) 2400)]
                (.encodeToString (Base64/getEncoder) (java.util.Arrays/copyOfRange bytes (int at) (int (min (alength bytes) (+ at 2400))))))]
    (replies (step session (str "det:ask " fifo " " (:id message) " " (string/join " " parts))))))

(defn start-repl
  "The session's relay to the program's nREPL server in `node` on `port`, then an nREPL session
  of its own. A warm server (the node's command, up before the setup's snapshot) answers at
  once; else the program's is started now (run nrepl <port>)."
  [session node port]
  (let [fifo (str "/opt/determinismo/records/.nrepl-" port)
        ready? #(string/includes? % "nrepl_relay_ready")]
    (background session (str "det-nodes exec " (name node) " /opt/determinismo/bin/det-nrepl-relay serve " port " " fifo))
    (when-not (ready? (until session 1500 "event=nrepl_relay_ready"))
      (background session (str "det-nodes exec " (name node) " /opt/workload/run nrepl " port))
      (let [output (until session 180000 "event=nrepl_relay_ready")]
        (when-not (ready? output)
          (throw (ex-info "the guest's nREPL server did not start" {:output output})))))
    (reset! (:repl session) {:fifo fifo :counter (atom 0)})
    (let [clone (first (ask session {:op "clone" :id "det-clone"}))]
      (swap! (:repl session) assoc :session (get clone "new-session"))
      session)))

(defn eval
  "Evaluates `code` in the guest's REPL: {:value :out :err :ex}, the replies' texts joined."
  [session code]
  (let [{:keys [counter] nrepl-session :session} @(:repl session)
        id (str "det-" (swap! counter inc))
        replies (ask session {:op "eval" :code code :id id :session nrepl-session})]
    (into {} (for [key ["value" "out" "err" "ex"]
                   :let [texts (keep #(get % key) replies)]
                   :when (seq texts)]
               [(keyword key) (string/join texts)]))))

;; Replays ---------------------------------------------------------------------------------------

(defn replay
  "A run's timeline replayed (POST /runs/<id>/replay): to a moment (:at-ms, or :until a
  condition), a change tried there (:exec a command, or :steps [{:exec ...} {:wait_ms ...}
  {:until ... :timeout_ms ...}]), then on to its end with :continue: what the timeline does
  with the change. Its output (the verdict at its end). A session's timeline (open's :timeline)
  replays as any: its steps from its tape.

    (replay serve 438 {:branch 60 :at-ms 117000 :continue true
                       :steps [{:exec \"det-nodes kill pdb\"} {:exec \"det-nodes start pdb\"}]})"
  [serve run {:keys [branch at-ms until exec steps continue fresh-seed] :or {branch 0}}]
  (request serve (str "/runs/" run "/replay")
           (cond-> {:branch branch}
             at-ms (assoc :at_vtime_ms at-ms)
             until (assoc :until until)
             exec (assoc :exec exec)
             steps (assoc :steps (vec steps))
             continue (assoc :continue true)
             fresh-seed (assoc :fresh_seed fresh-seed))))

(defn verdict
  "A run's or a replay's output, its verdict lines only (timelines, the multiverse, properties)."
  [output]
  (filter #(re-find #"^\[branch|multiverse:|^  (PASS|FAIL|----)" %) (string/split-lines output)))

;; Runs ------------------------------------------------------------------------------------------

(defn start-run
  "A run started as `POST /runs` takes it ({:program :scenario :branches :time_budget ...}, or
  :from_branch and :from_vtime_ms for one from another run's moment): its id."
  [serve request]
  (:id (post serve "/runs" request)))

(defn run "A run's state and stats." [serve id] (post-get serve (str "/runs/" id)))

(defn runs "Every run: id, state, system, scenario." [serve] (post-get serve "/runs"))

(defn output
  "A run's output: its last `lines` lines, the explorer's own (progress, timelines, verdicts)
  unless :consoles."
  [serve id {:keys [lines consoles] :or {lines 40}}]
  (request serve (str "/runs/" id "/output?lines=" lines (when-not consoles "&explorer=1")) nil))

(defn stop! "The run stopped." [serve id] (post serve (str "/runs/" id "/stop") {}))

(defn watch
  "The run as it goes: its explorer's new lines printed (or each given to `f`) every
  `interval-ms` until it ends. Its state at the end."
  ([serve id] (watch serve id {}))
  ([serve id {:keys [interval-ms f] :or {interval-ms 2000 f println}}]
   (loop [seen #{}]
     (let [lines (string/split-lines (output serve id {:lines 200}))
           fresh (remove seen lines)]
       (run! f fresh)
       (let [{:keys [state] :as current} (run serve id)]
         (if (= "running" state)
           (do (Thread/sleep (long interval-ms)) (recur (into seen lines)))
           current))))))
