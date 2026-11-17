;; SPDX-License-Identifier: MIT
;; determinismo's HTTP API (src/serve.zig) from Clojure, babashka or jank: runs, their timelines
;; and properties, events (query, SQL), replays, causality analyses, starting and stopping runs.
;; The debugger's sessions are determinismo.debug.
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

(defn causality-wait
  "Waits for an analysis to finish (looking every `every-ms`), and returns it."
  ([id n] (causality-wait id n 3000))
  ([id n every-ms]
   (loop []
     (let [analysis (causality id n)]
       (if (:done analysis) analysis (do (http/sleep-ms every-ms) (recur)))))))

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
