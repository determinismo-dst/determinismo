;; SPDX-License-Identifier: MIT
;; determinismo's HTTP API (src/serve.zig) from Clojure, babashka or jank: runs, their timelines
;; and properties, events (query, SQL), replays, a node's file at a moment, timelines from a
;; moment, causality, shrinking and explaining analyses, starting, stopping and resuming runs.
;; The debugger's sessions are determinismo.debug, Quint is determinismo.quint, and
;; determinismo.help lists everything with its arguments (`(help)`, `(help "replay")`).
;;
;;   (require '[determinismo.api :as api])
;;   (binding [api/*url* "http://127.0.0.1:7878"] (api/runs))  ; $DETERMINISMO_URL, else this
;;   (api/properties 93)
;;   (api/query 93 {:condition "event=fault" :branch 4862 :up_to_vtime 24.5})
;;   (api/sql 93 "SELECT count(*) FROM events")
(ns determinismo.api
  (:require [clojure.string :as str]
            [determinismo.http :as http]
            [determinismo.json :as json]
            [determinismo.tap :as tap]))

(def ^:dynamic *url* http/url) ; $DETERMINISMO_URL, else http://127.0.0.1:7878

(defn request
  "Any endpoint: `method` (:get, :post, :put), a path under *url* or a whole URL, a body (a map
  sent as JSON, a string as it is). The answer's body, a string; a status of 400 or more thrown."
  ([method path] (request method path nil))
  ([method path body]
   (let [url (if (str/starts-with? path "http") path (str *url* path))
         [status text] (http/request method url (cond (nil? body) nil
                                                      (string? body) body
                                                      :else (json/write-json body)))]
     (when (>= status 400)
       (throw (ex-info (str "determinismo: " status " " text) {:status status :body text})))
     text)))

(defn- lines [body]
  (mapv json/read-json (remove str/blank? (str/split-lines (or body "")))))

(defn- parse
  "A JSON document, or JSON lines (queries answer one value per line)."
  [body]
  (let [values (lines body)]
    (if (= 1 (count values)) (first values) values)))

(defn runs [] (parse (request :get "/runs")))
(defn run [id] (parse (request :get (str "/runs/" id))))

(defn- decide-text
  "Fixed decisions as serve takes them: {\"knob.mode\" 2, \"fault\" \"pause\"} as
  \"knob.mode=2,fault=pause\"."
  [decide]
  (if (map? decide)
    (str/join "," (map (fn [[k v]] (str (if (keyword? k) (name k) k) "=" (if (keyword? v) (name v) v))) decide))
    decide))

(defn start-run
  "Starts a run: {:program | :compose, :scenario, :profile, :seed, :branches, :time_budget,
  :faults, :decide, ...} (serve's RunRequest). `:decide` fixes named decisions in every timeline
  (a map of a label to a range's number or an option's name): the run as it goes with that
  choice. {:id ...}. With :plan true nothing starts: what it would be (how many timelines its
  budget buys at the rate of the last run like it, the named choices that one drew), a plan
  `execute` starts."
  [request-map]
  (let [asked (cond-> request-map (:decide request-map) (update :decide decide-text))]
    (if (:plan asked)
      (let [planned (assoc (parse (request :post "/runs" asked)) :request (dissoc request-map :plan))]
        (tap/tell :run/plan planned planned))
      (let [started (parse (request :post "/runs" asked))]
        (tap/tell :run/start {:run (:id started) :request asked} started)))))

(defn execute
  "A run's plan made real: the run it planned, with the seed it imagined, started ({:id ...})."
  [planned]
  (start-run (assoc (:request planned) :seed (:seed planned))))

(defn imagined
  "The setup a run's plan imagined for its first-generation timeline `index`: its seed and the
  choices it would draw first, [{:name :drew :fixed}]."
  [planned index]
  (let [setup (first (filter (fn [s] (= index (:index s))) (:setups planned)))]
    (tap/tell :run/imagined {:plan planned :setup setup} setup)))

(defn setups-check
  "A run's plan against the run it started: for each imagined timeline that has drawn (ended and
  taken in), how many of its choices it drew as imagined, and the ones it did not; the others
  pending. {:matched :choices :pending :timelines [...]}"
  [planned run-id]
  (let [rows (parse (request :post (str "/runs/" run-id "/sql")
                             {:sql (str "SELECT timeline, name, arg_min(drew, pull) AS drew FROM timeline_draws"
                                        " WHERE part = 'own' AND timeline < " (count (:setups planned))
                                        " GROUP BY timeline, name")}))
        rows (if (map? rows) [rows] rows)
        actual (into {} (map (fn [r] [[(:timeline r) (:name r)] (:drew r)]) rows))
        drawn (set (map :timeline rows))
        timelines (mapv (fn [setup]
                          (if-not (contains? drawn (:index setup))
                            {:index (:index setup) :pending true}
                            (let [parted (filterv (fn [d] (not= (str (:drew d)) (str (get actual [(:index setup) (:name d)]))))
                                                  (:draws setup))]
                              {:index (:index setup) :choices (count (:draws setup))
                               :as-imagined (- (count (:draws setup)) (count parted))
                               :parted (mapv (fn [d] {:name (:name d) :imagined (:drew d)
                                                      :drew (get actual [(:index setup) (:name d)])})
                                             parted)})))
                        (:setups planned))
        checked {:timelines timelines
                 :choices (apply + (keep :choices timelines))
                 :matched (apply + (keep :as-imagined timelines))
                 :pending (count (filter :pending timelines))}]
    (tap/tell :run/check (assoc checked :run run-id) checked)))

(defn stop-run [id] (parse (request :post (str "/runs/" id "/stop"))))
(defn resume-run
  "Resumes a run that was stopped or interrupted, from where it was (its record, its holders)."
  [id]
  (parse (request :post (str "/runs/" id "/resume"))))
(defn output [id] (request :get (str "/runs/" id "/output")))

(defn timelines
  "Every finished timeline (index, seed, outcome, vtime_ns, failing, path, why, ...), or those
  after the first `offset` ingested."
  ([id] (parse (request :get (str "/runs/" id "/timelines"))))
  ([id offset] (parse (request :get (str "/runs/" id "/timelines?offset=" offset)))))

(defn properties [id]
  (let [judged (parse (request :get (str "/runs/" id "/properties")))]
    (tap/tell :properties {:run id :properties judged} judged)))
(defn discovery [id] (parse (request :get (str "/runs/" id "/discovery"))))
(defn findings [id] (parse (request :get (str "/runs/" id "/findings"))))

(defn triage
  "The run's triage report (Markdown): its failing properties, each with its first failing
  timeline, how often it failed and what came before it. nil for a run that has none."
  [id]
  (let [[status text] (http/request :get (str *url* "/runs/" id "/triage") nil)]
    (cond (= status 404) nil
          (>= status 400) (throw (ex-info (str "determinismo: " status " " text) {:status status :body text}))
          :else text)))

(defn failures
  "Every failing evaluation of the run, as the map marks it: {:property :timeline :vtime_ns ...}."
  [id]
  (lines (request :get (str "/runs/" id "/failures"))))

(defn logged
  "What the run's nodes logged, by template: [{:node :level :template :timelines :lines
  :first_timeline :example ...}], one a template (a line's words with its numbers and ids left
  out)."
  [id]
  (json/read-json (request :get (str "/runs/" id "/logged"))))

(defn ranges
  "The ranges the run learned (the highest and lowest of each value its program asked to
  track): each with its record and the timeline holding it."
  [id]
  (parse (request :get (str "/runs/" id "/ranges"))))

(defn activity
  "Where the run's workers' time went, minute by minute: {:workers :minute_s :minutes [{:timelines
  :vtime_s :wait_s :busy_s {...} :running ...}]}: its explorer, node makers, holders and
  verifier."
  [id]
  (json/read-json (request :get (str "/runs/" id "/activity"))))

(defn automations
  "What the commands run at each failing property's first counterexample said: {:property
  :timeline :vtime_ns :exec :output}."
  [id]
  (lines (request :get (str "/runs/" id "/automations"))))

(defn query
  "Events matching a condition (query.zig): {:condition, :branch, :up_to_vtime (s), :output
  (events | count | branches | marks), :timelines, :limit, ...}. A vector, one per event."
  [id request-map]
  (let [found (lines (request :post (str "/runs/" id "/query") request-map))]
    (tap/tell :query {:run id :request request-map :events found} found)))

(defn query-at
  "`query` at a run's whole URL (as causality planners are told it: http://host:port/runs/<id>)."
  [run-url request-map]
  (lines (request :post (str run-url "/query") request-map)))

(defn watched
  "A JVM node's watched field or method (DETERMINISMO_WATCH in its environment: docs/SDKS.md)
  through a run's events: each store's :value or each call's :args, with its :object (the
  instance; none for a static one) and its moment, in every timeline (:branch for one, :limit
  10,000). `member` names it as the watch did, `com.x.Raft.currentTerm` (contained: `Raft.term`
  matches no other). One event a watch says its count was over: {:over n}.
  -> [{:branch :vtime_ns :name :value | :args :object} ...]"
  ([id member] (watched id member {}))
  ([id member options]
   (let [asked (cond-> {:condition (str "event=watch details.name~" member) :limit (or (:limit options) 10000)}
                 (:branch options) (assoc :branch (:branch options)))
         found (lines (request :post (str "/runs/" id "/query") asked))
         said (mapv (fn [e]
                      (merge (select-keys e [:branch :vtime_ns])
                             (select-keys (get-in e [:event :details]) [:name :value :args :object :over])))
                    found)]
     (tap/tell :watched {:run id :member member :request asked :found said} said))))

(defn events [id request-map] (lines (request :post (str "/runs/" id "/events") request-map)))
(defn sql [id text]
  (let [rows (parse (request :post (str "/runs/" id "/sql") {:sql text}))]
    (tap/tell :sql {:run id :sql text :rows rows} rows)))

;; A run's named draws (src/draws.zig): what each timeline drew for each label the guest named
;; (knob.<name>, a fault's parameters, swarm.<name>, sdk.decide's options), as the explorer
;; answered it. Read from the run's database (store.zig's timeline_draws), runs recorded since
;; 2026-11-15.

(defn- sql-string [text] (str "'" (str/replace (str text) "'" "''") "'"))

;; A draw is said as `drew`: an option's name (sdk.decide's options: "fault" is drawn among a
;; varying subset, an index names another option in another one), else its number.

(defn draws
  "A timeline's draws, its setup's and ancestors' parts and its own, in the order drawn: a map a
  value, {:part :name :kind :count :drew :value :pull :after_ns :overridden}. `name-prefix`
  keeps the labels starting with it (\"knob.\", \"fault.\")."
  ([id timeline] (draws id timeline ""))
  ([id timeline name-prefix]
   (let [rows (parse (request :post (str "/runs/" id "/sql")
                              {:sql (str "SELECT part, name, kind, count, drew, value, pull, after_ns, overridden"
                                         " FROM timeline_draws WHERE timeline = " timeline
                                         " AND starts_with(name, " (sql-string name-prefix) ") ORDER BY pull")}))
         drawn (if (map? rows) [rows] (vec rows))]
     (tap/tell :draws {:run id :timeline timeline :draws drawn} drawn))))

(defn- labels-of
  "Rows of (name, drew, counts...) as labels, each with its values in the order given."
  [rows counts]
  (->> (group-by :name rows)
       (map (fn [[name values]]
              {:name name :kind (:kind (first values)) :count (:count (first values))
               :values (mapv (fn [row] (merge {:drew (:drew row)} (select-keys row counts))) values)}))
       (sort-by :name)
       vec))

(defn draw-sets
  "A run's labels across its explored timelines (sessions left out): per label, per value drawn,
  how many timelines drew it (once each, whatever their part).
  [{:name :kind :values [{:drew :timelines}]}]."
  ([id] (draw-sets id ""))
  ([id name-prefix]
   (let [rows (parse (request :post (str "/runs/" id "/sql")
                              {:sql (str "SELECT name, drew, any_value(kind) AS kind, max(count) AS count, count(DISTINCT timeline) AS timelines"
                                         " FROM timeline_draws WHERE timeline IN (SELECT branch FROM explored)"
                                         " AND starts_with(name, " (sql-string name-prefix) ")"
                                         " GROUP BY name, drew ORDER BY name, min(value), drew")}))
         sets (labels-of (if (map? rows) [rows] rows) [:timelines])]
     (tap/tell :draw/sets {:run id :labels sets} sets))))

(defn draw-split
  "What the timelines failing `property` drew, against the others (explored ones): per label and
  value drawn, how many failing and passing timelines drew it (once each). The swarm's
  question: which choices do the failures share? {:property :failing :passing :labels [{:name
  :kind :values [{:drew :failing :passing}]}]}."
  ([id property] (draw-split id property ""))
  ([id property name-prefix]
   (let [failing-sql (str "SELECT DISTINCT timeline FROM timeline_properties WHERE message = "
                          (sql-string property) " AND failed_ns IS NOT NULL"
                          " AND timeline IN (SELECT branch FROM explored)")
         totals (let [answer (parse (request :post (str "/runs/" id "/sql")
                                             {:sql (str "SELECT (SELECT count(*) FROM (" failing-sql ")) AS failing,"
                                                        " (SELECT count(*) FROM explored) AS explored")}))]
                  (if (map? answer) answer (first answer)))
         rows (parse (request :post (str "/runs/" id "/sql")
                              {:sql (str "WITH failing AS (" failing-sql "),"
                                         " drawn AS (SELECT DISTINCT timeline, name, drew, kind, count, value FROM timeline_draws"
                                         " WHERE timeline IN (SELECT branch FROM explored)"
                                         " AND starts_with(name, " (sql-string name-prefix) "))"
                                         " SELECT name, drew, any_value(kind) AS kind, max(count) AS count,"
                                         " count(DISTINCT timeline) FILTER (WHERE timeline IN (SELECT timeline FROM failing)) AS failing,"
                                         " count(DISTINCT timeline) FILTER (WHERE timeline NOT IN (SELECT timeline FROM failing)) AS passing"
                                         " FROM drawn GROUP BY name, drew ORDER BY name, min(value), drew")}))
         split {:property property :failing (:failing totals)
                :passing (- (:explored totals) (:failing totals))
                :labels (labels-of (if (map? rows) [rows] rows) [:failing :passing])}]
     (tap/tell :draw/split (assoc split :run id) split))))

(defn faults
  "The faults a timeline went through up to `up-to-ms` (its ancestors' included), as
  {:vtime_ms :kind :node :peer :details}."
  ([id branch up-to-ms] (faults (str *url* "/runs/" id) branch up-to-ms nil))
  ([run-url branch up-to-ms _]
   (for [event (query-at run-url {:condition "event=fault" :branch branch
                                  :up_to_vtime (/ (+ up-to-ms 1) 1000.0) :limit 100000})
         :let [details (get-in event [:event :details])]]
     {:vtime_ms (quot (:vtime_ns event) 1000000)
      :kind (:kind details) :node (:node details) :peer (:peer details) :details details})))

(defn replay
  "Replays one timeline: {:branch, :at_vtime_ms | :until (:rewind_ms), :exec}. Its output."
  [id request-map]
  (let [output (request :post (str "/runs/" id "/replay") request-map)]
    (tap/tell :replay {:run id :request request-map :output output} output)))

(defn causality-start
  "Starts a causality analysis: {:branch :property :points :futures :refine :moments_max
  :jump_min :gap_min_ms :planner}. Its {:id}."
  [id request-map]
  (parse (request :post (str "/runs/" id "/causality") request-map)))

(defn causality
  "Every analysis of a run, or one: {:id :done :of {...} :points [...]}."
  ([id] (parse (request :get (str "/runs/" id "/causality"))))
  ([id n] (parse (request :get (str "/runs/" id "/causality/" n)))))

;; Words in a URL's query: what is not a letter, a digit or one of -_.~ as %XX (UTF-8 bytes of
;; anything not ASCII are left as they are: serve reads them as they come).
(def ^:private percent-digits "0123456789ABCDEF")

(defn- percent [c]
  (let [n (int c)]
    (if (or (and (>= n 48) (<= n 57)) (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122))
            (= c \-) (= c \_) (= c \.) (= c \~) (> n 127))
      (str c)
      (str "%" (nth percent-digits (quot n 16)) (nth percent-digits (mod n 16))))))

(defn- query-text [text]
  (apply str (map percent text)))

(defn causality-logs
  "The node output of an analysis's explained future `k` (its lines holding `grep`, when given):
  what the nodes said in the future that did, or did not, fail."
  ([id n k] (lines (request :get (str "/runs/" id "/causality/" n "/explained/" k "/logs"))))
  ([id n k grep] (lines (request :get (str "/runs/" id "/causality/" n "/explained/" k "/logs?grep=" (query-text grep))))))

(defn causality-wait
  "Waits for an analysis to finish (looking every `every-ms`), and returns it."
  ([id n] (causality-wait id n 3000))
  ([id n every-ms]
   (loop []
     (let [analysis (causality id n)]
       (if (:done analysis) analysis (do (http/sleep-ms every-ms) (recur)))))))

;; Shrinking and explaining, beside causality: started, listed, stopped as it is.
(defn shrink-start
  "Starts shrinking a failing timeline: {:branch :property :timelines}: the fewest of its faults
  its property's failure still needs (each tried in `timelines` futures). Its {:id}."
  [id request-map]
  (parse (request :post (str "/runs/" id "/shrink") request-map)))

(defn shrinks
  "Every shrinking of a run: [{:id :of :done :result :progress}]."
  [id]
  (parse (request :get (str "/runs/" id "/shrink"))))

(defn shrink-stop [id n] (parse (request :post (str "/runs/" id "/shrink/" n "/stop"))))

(defn explain-start
  "Starts explaining a failing timeline: {:branch :property :faults :variants}: which details of
  its last `faults` faults its failure needs (each drawn again `variants` times beside a
  control). Its {:id}."
  [id request-map]
  (parse (request :post (str "/runs/" id "/explain") request-map)))

(defn explains
  "Every explanation of a run: [{:id :of :done :result :progress}]."
  [id]
  (parse (request :get (str "/runs/" id "/explain"))))

(defn explain-stop [id n] (parse (request :post (str "/runs/" id "/explain/" n "/stop"))))

(defn analysis-wait
  "Waits for a shrinking or an explanation (`listing`: shrinks or explains) to finish, looking
  every `every-ms`, and returns it."
  ([listing id n] (analysis-wait listing id n 3000))
  ([listing id n every-ms]
   (loop []
     (let [found (first (filter (fn [item] (= n (:id item))) (listing id)))]
       (if (or (nil? found) (:done found)) found (do (http/sleep-ms every-ms) (recur)))))))

;; At a moment of a timeline: a node's file as it was, the lines its events left out, new
;; timelines from there. Each marks the moment on the visualization's map.
(defn extract
  "A node's file as it was at a moment of a timeline (the timeline replayed to it): {:branch
  :at_vtime_ms :node :path}. Its text (`extract-to` for a binary file)."
  [id request-map]
  (let [text (request :post (str "/runs/" id "/extract") request-map)]
    (tap/tell :replay {:run id :request (select-keys request-map [:branch :at_vtime_ms])
                       :output (str "extracted " (:node request-map) ":" (:path request-map))}
              text)))

(defn extract-to
  "`extract`, its bytes written to the local file `path` as they are (a database, a core dump).
  The path."
  [id request-map path]
  (let [[status written] (http/download (str *url* "/runs/" id "/extract") (json/write-json request-map) path)]
    (when (>= status 400)
      (throw (ex-info (str "determinismo: " status " extracting " (:node request-map) ":" (:path request-map)) {:status status})))
    (tap/tell :replay {:run id :request (select-keys request-map [:branch :at_vtime_ms])
                       :output (str "extracted " (:node request-map) ":" (:path request-map) " to " path)}
              written)))

(defn inject
  "A file put into a node at a moment of a timeline, then the replay goes on as asked: {:branch
  :at_vtime_ms (or :until :rewind_ms) :node :path :from (a local file) | :text (the file's
  content) :mode (octal, \"644\") :exec (a command after it) | :steps [...] :continue (on to the
  timeline's end: a new future with the change) :fresh_seed}. The replay's output: \"[injected]\"
  once the file is there, then what followed. A patched binary is put in place of the node's
  and the node restarted by :exec, as a person tries a fix."
  [id request-map]
  (let [content (if (:from request-map) (http/file-base64 (:from request-map)) (http/text-base64 (or (:text request-map) "")))
        file (cond-> {:node (:node request-map) :path (:path request-map) :content content}
               (:mode request-map) (assoc :mode (:mode request-map)))]
    (replay id (assoc (dissoc request-map :node :path :from :text :mode) :inject file))))

(defn recover
  "The output lines a timeline's events left out near a moment (Antithesis's \"Recover filtered
  logs\"): {:branch :vtime_ns :window_ms}. Oldest first."
  [id request-map]
  (let [found (lines (request :post (str "/runs/" id "/recover") request-map))]
    (tap/tell :replay {:run id :request {:branch (:branch request-map) :at_vtime_ms (quot (:vtime_ns request-map) 1000000)}
                       :output (str (count found) " lines recovered")}
              found)))

(defn fork
  "New timelines from a moment of one: the run's own request (its system, scenario, faults),
  `branches` of them, flat, each from timeline `branch` at `at-vtime-ms` on (explore's
  --from-branch --from-vtime-ms); `more` merged into the request (:faults, :decide, ...). The
  new run, {:id ...}."
  ([id branch at-vtime-ms branches] (fork id branch at-vtime-ms branches {}))
  ([id branch at-vtime-ms branches more]
   (let [original (:request (run id))
         ;; What a run of its own is not: a budget, a tree's generations, a plan, a CI job, a
         ;; checkpoint's or a session's start.
         asked (merge (apply dissoc original [:time_budget :generation :horizon :plan :ci :repeat :from_snapshot
                                              :from_run :checkpoint :checkpoint_exec :checkpoint_steps :build
                                              :return_offsets :return_branches])
                      {:from_branch branch :from_vtime_ms at-vtime-ms :branches branches :branching "flat"}
                      more)]
     (tap/tell :replay {:run id :request {:branch branch :at_vtime_ms at-vtime-ms} :output (str branches " timelines from here")} nil)
     (start-run asked))))

(defn wait-run
  "Waits for a run to finish (looking every `every-ms`), and returns it."
  ([id] (wait-run id 2000))
  ([id every-ms]
   (loop []
     (let [found (run id)]
       (if (#{"running" "queued" "starting"} (:state found))
         (do (http/sleep-ms every-ms) (recur))
         (tap/tell :run/done {:run id :state (:state found)} found))))))

(defn strategies [] (parse (request :get "/strategies")))

(defn machines
  "The machines serve holds (a sandbox's, a CI job's): {:machine :alive :directory
  :checkpoints}."
  []
  (parse (request :get "/machines")))

(defn build
  "serve's build: {:commit :explorer :kernel :initrd}, what new runs boot with."
  []
  (parse (request :get "/build")))
