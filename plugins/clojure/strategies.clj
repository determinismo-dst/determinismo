;; SPDX-License-Identifier: MIT
;; Exploration strategies in Clojure on the JVM, served over TCP to `determinismo explore
;; --strategy tcp://127.0.0.1:<port>` (protocol v1, docs/PLUGINS.md), with an nREPL server:
;; redefine a strategy (or write a new one) from your editor, and the next generation uses it. No
;; rebuild, no restart. From this directory (deps.edn):
;;
;;   clojure -M -m strategies [--port 9100] [--nrepl 1667] [--control 9101]
;;                                     [--strategy rarity] [--events-dir <explore's --events-dir>]
;;                                     [--planner-port 9102] [--planner faults]
;;                                     [--jev-key-file .secrets/.jev] [--jev-system "<the system>"]
;;                                     [--strategy-ports rarity:9110,jev:9111]
;;
;; Causality planners too (`determinismo causality --planner tcp://127.0.0.1:9102`, or the
;; page's planner field): which moments of a failing timeline to analyze next, and how many
;; futures each (causality.zig's protocol). `(use-planner! :faults)` switches; `@plans` keeps
;; every round asked and answered. They reach the run over its HTTP API (clients/clojure's determinismo.api).
;;
;; A strategy is a map in `strategies`: `:returns` gets the generation's candidates (each
;; timeline: its span and the behaviors it reached, with how many timelines reached them) and
;; chooses up to `count` moments to branch from, each {:branch :vtime_ns :reason} (fewer: the
;; explorer fills the rest); nil or [] leaves it to the explorer. `(use-strategy! :rarity)` switches; the control port takes "use <name>" (for
;; scripts: bench/explore.py). Everything seen is kept for the REPL: `@generations` (candidates and
;; choices), `@ends` (each timeline's outcome and failing properties), and `(timeline n)` reads a
;; whole timeline's events from the events directory.
(ns strategies
  (:require [babashka.http-client :as http]
            [nrepl.server :as nrepl]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.pprint :as pprint]
            [clojure.string :as str]
            [determinismo.api :as api])
  (:import (java.net ServerSocket)))

(def ms 1000000)

;; What the strategies saw ------------------------------------------------------------------------

(defonce generations (atom [])) ; [{:generation :candidates :chosen :strategy}]
(defonce ends (atom {}))        ; branch index -> {:outcome :events :failing}
(defonce starts (atom {}))      ; branch index -> {:seed :from}
(defonce events-dir (atom nil))

(defn timeline
  "A timeline's events (its own part: a tree branch begins inside its ancestors). An ended
  timeline's are compressed (src/event_files.zig: branch-<n>.jsonl.zst), a running one's plain."
  [index]
  (let [ended (io/file @events-dir (str "branch-" index ".jsonl.zst"))
        stream (if (.exists ended)
                 (com.github.luben.zstd.ZstdInputStream. (io/input-stream ended))
                 (io/input-stream (io/file @events-dir (str "branch-" index ".jsonl"))))]
    (with-open [reader (io/reader stream)]
      (doall (map #(json/parse-string % true) (line-seq reader))))))

(defn failing [] (into {} (filter (comp seq :failing val)) @ends))

;; Strategies -------------------------------------------------------------------------------------

(defn- room-end [{:keys [start_ns end_ns]}] (+ start_ns (quot (* 4 (- end_ns start_ns)) 5)))

(defn- clamp-moment [{:keys [start_ns end_ns]} at]
  (-> at (max (+ start_ns ms)) (min (- end_ns ms))))

(defn- new-behaviors [candidate] (filter #(pos? (:new_in_generation %)) (:behaviors candidate)))

(declare rarity-frontier)

(def ^:dynamic *archive*
  "The explorer's Go-Explore archive cells offered with this generation's candidates, most
  promising first ({:branch :vtime_ns :label :timelines :returns :paid}); empty from explorers
  that send none."
  [])

(defn archive-returns
  "The first `n` of the explorer's archive cells as returns: the explorer credits a cell returned
  to as its own return."
  [n]
  (->> *archive*
       (take n)
       (map (fn [cell]
              {:branch (:branch cell) :vtime_ns (:vtime_ns cell)
               :reason (str "archive: just after " (:label cell) ", reached by " (:timelines cell)
                            " timelines, returned to " (:returns cell) " times, " (:paid cell)
                            " of them finding something new")}))))

(defn rarity
  "The explorer's own rule: Go-Explore's frontier (timelines scored by their new behaviors, each
  weighing 1 / the timelines of its generation that reached it; return just after the rarest one
  that leaves room to go on) for half the returns, its archive's most promising cells for the
  rest, as the explorer alone does."
  [generation candidates count]
  (let [frontier (rarity-frontier generation candidates count)
        kept (if (seq *archive*) (take (quot (inc count) 2) frontier) frontier)]
    (concat kept (archive-returns (- count (clojure.core/count kept))))))

(defn rarity-archive2
  "The explorer's rule leaning on its archive: one frontier moment, the rest archive cells (in
  the raft A/B's first seeds the archive's returns failed 12 of 104, the frontier's 9 of 139)."
  [generation candidates count]
  (let [frontier (rarity-frontier generation candidates count)
        kept (if (seq *archive*) (take 1 frontier) frontier)]
    (concat kept (archive-returns (- count (clojure.core/count kept))))))

(defn rarity-frontier
  "Go-Explore's frontier as the explorer ranks it."
  [generation candidates count]
  (->> candidates
       (keep (fn [c]
               (let [fresh (new-behaviors c)
                     roomy (filter #(<= (:vtime_ns %) (room-end c)) fresh)]
                 (when (seq roomy)
                   (let [best (apply min-key :new_in_generation roomy)] ; The latest among equals.
                     {:score (reduce + (map #(/ 1.0 (:new_in_generation %)) fresh))
                      :branch (:branch c)
                      :vtime_ns (clamp-moment c (+ (:vtime_ns best) 1000))
                      :reason (str "rarity: just after " (:label best) ", reached first by "
                                   (:new_in_generation best) " timelines of generation "
                                   generation)})))))
       (sort-by (comp - :score))
       (take count)))

(defn rarest-ever
  "Behaviors rare across the whole exploration (fewest timelines before), not just new to the
  generation: return just after the rarest behavior any candidate reached."
  [_generation candidates count]
  (->> candidates
       (mapcat (fn [c] (for [b (:behaviors c) :when (<= (:vtime_ns b) (room-end c))] [c b])))
       (sort-by (fn [[_ b]] [(:timelines_before b) (- (:vtime_ns b))]))
       (map (fn [[c b]] {:branch (:branch c)
                         :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                         :reason (str "rarest-ever: " (:label b) ", reached by "
                                      (:timelines_before b) " timelines before")}))
       (reduce (fn [chosen r] (if (some #(= (:branch %) (:branch r)) chosen) chosen (conj chosen r)))
               [])
       (take count)))

(defn uniform
  "A baseline: random timelines, random moments."
  [_generation candidates count]
  (for [c (take count (shuffle (filter #(> (- (:end_ns %) (:start_ns %)) (* 2 ms)) candidates)))]
    {:branch (:branch c)
     :vtime_ns (+ (:start_ns c) ms (rand-int (max 1 (- (:end_ns c) (:start_ns c) (* 2 ms)))))
     :reason "uniform: a random moment of a random timeline"}))

(defn deepest
  "Depth first: the latest new behavior of each timeline, the timelines with the latest first."
  [generation candidates count]
  (->> candidates
       (keep (fn [c] (when-let [b (last (sort-by :vtime_ns (new-behaviors c)))]
                       {:branch (:branch c)
                        :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                        :reason (str "deepest: after " (:label b) " (generation " generation ")")})))
       (sort-by (comp - :vtime_ns))
       (take count)))

;; Jev (TypeSafe AI's System One model, api.typesafe.ai): typed answers with calibrated
;; probabilities, about 0.1 s a call. `:jev` asks after each generation one "noul" (a
;; probability) per timeline, that branching again just after its rarest new behavior makes one
;; of the system's properties fail, and returns to the likeliest; `:jev-blend` lets rarity propose
;; and Jev reorder (rarity times the probability). What Jev is told the system is: `jev-system`
;; (the control port's "jev-system <text>", or `(reset! jev-system "...")` from the REPL); its key
;; comes from --jev-key-file or $TYPESAFE_API_KEY. Every call is kept in `@jev-calls`. Without an
;; answer the explorer chooses: Jev never stalls an exploration.

(def jev-url "https://api.typesafe.ai/v1/systemone")
(defonce jev-key (atom (System/getenv "TYPESAFE_API_KEY")))
(defonce jev-system (atom "a distributed system under test")) ; jev-system-default
;; Descriptions by hand for the systems they describe: a piece of a run's compose file or
;; program path -> the text (`(swap! jev-systems assoc "raft-poc" "...")`, the control port's
;; `jev-system-for <piece> <text>`). A run under serve gets only its own.
(defonce jev-systems (atom {}))
(defonce jev-calls (atom [])) ; [{:state :questions :answers :ms}]
(def jev-questions-max 32)
(defn- clip [text size] (if (> (count text) size) (subs text 0 size) text))

(def jev-system-default "a distributed system under test")

(declare current-run index-hex adaptive-returns advise-every! evolve-returns evolve-every! evolve-minutes
         learn-returns learn-end learn-chosen run-failed mix-returns mix-end mix-chosen
         council-returns council-review-every! council-review-minutes council-decide council-end
         council-ender-event moment-kind timing-decisions timing-options) ; Defined further down; a fresh JVM compiles in order.
(def advise-minutes 5)

;; What Jev is told the system is, from the run itself under serve (its hello's run_url): its
;; program or compose file, scenario and faults, and its properties as serve catalogs them, the
;; failing ones marked; read again every five minutes. `jev-system`, when set, comes first.
(defonce jev-run-context (atom {:run nil :at 0 :context nil}))

(defn- http-json [url & {:keys [timeout] :or {timeout 10000}}]
  (let [response (http/get url {:timeout timeout :throw false})]
    (when (= 200 (:status response)) (json/parse-string (:body response) true))))

(defn- fs-name [path] (last (str/split path #"/")))

(def system-crash-properties
  #{"no unexpected container exits" "no process crashes (segfault, illegal instruction, ...)"})

(defn- run-context [run-url]
  (let [request (:request (http-json run-url))
        ;; The system's own (an assertion with a place in its code or workload), and the
        ;; platform's two that catch its crashes; not the platform's checks of itself.
        properties (filter #(or (:location %) (contains? system-crash-properties (:message %)))
                           (http-json (str run-url "/properties")))
        safety? #(contains? #{"always" "always_or_unreachable" "unreachable"} (:type %))
        named (fn [property] (str (clip (:message property) 160)
                                  (when (= "failing" (:status property)) " (failing already)")))]
    (cond-> {:system_under_test (str (or (some-> (:program request) fs-name) (:compose request) "?")
                                     ", scenario " (or (:scenario request) "default")
                                     (some->> (:profile request) (str ", profile ")))
             :faults (or (:faults request) "the defaults")}
      (seq properties)
      (assoc :properties_a_bug_makes_false (vec (take 48 (map named (filter safety? properties))))
             :targets_not_reached_yet (vec (take 48 (for [property properties
                                                          :when (not (safety? property))
                                                          :when (not= "passing" (:status property))]
                                                      (clip (:message property) 160))))))))

(defn jev-context
  "The system as Jev's state gives it: `jev-system` when set, and the run's own (under serve)."
  []
  (let [run @current-run
        now (System/currentTimeMillis)
        cached @jev-run-context
        context (when (and (string? run) (str/starts-with? run "http"))
                  (if (and (= run (:run cached)) (< (- now (:at cached)) 300000))
                    (:context cached)
                    (let [context (try (run-context run)
                                       (catch Exception e
                                         (binding [*out* *err*] (println "jev: run context:" (ex-message e)))
                                         nil))]
                      (reset! jev-run-context {:run run :at now :context context})
                      context)))]
    (if context
      (let [under-test (:system_under_test context)
            by-hand (some (fn [[piece text]] (when (str/includes? under-test piece) text)) @jev-systems)]
        (cond-> context by-hand (assoc :system by-hand)))
      {:system @jev-system})))

;; What we ask Jev about: a failure the timeline has not had yet. Asked only "likely to make a
;; property fail", its most confident picks (>= 0.40) were timelines already failing: 14% of their
;; branches failed as the parent had, 1 of 252 anew (jev-wide's three raft runs, 2026-11-07).
(def jev-anew
  (str ", best one no timeline of this run has failed yet (the properties not marked failing: a "
       "bug not yet found), at least one that has not failed in this timeline yet (a new failure, "
       "not one already under way: a timeline that failed a property makes its branches fail it "
       "too, and finds nothing)"))

(defn jev-ask
  "Jev's answers by question id (keywords: :t12), {} without them."
  [state questions]
  (if (or (str/blank? @jev-key) (empty? questions))
    {}
    (let [started (System/nanoTime)]
      (try
        (let [response (http/post jev-url {:headers {"Authorization" (str "Bearer " @jev-key)
                                                     "Content-Type" "application/json"}
                                           :body (json/generate-string {:model "jev-latest" :state state
                                                                        :questions questions})
                                           :timeout 20000
                                           :throw false})
              answers (when (= 200 (:status response))
                        (:answers (json/parse-string (:body response) true)))]
          (swap! jev-calls #(conj (if (>= (count %) 256) (subvec % 1) %) ; The last 256.
                                  {:state state :questions questions :answers answers
                                 :ms (quot (- (System/nanoTime) started) 1000000)}))
          (when-not answers (binding [*out* *err*] (println "jev: status" (:status response))))
          (or answers {}))
        (catch Exception e
          (binding [*out* *err*] (println "jev: no answer:" (ex-message e)))
          {})))))

(defn- rarest-new
  "Just after the candidate's rarest new behavior that leaves room to go on (rarity's moment):
  {:at :label :reached}, or nil."
  [c]
  (let [roomy (filter #(<= (:vtime_ns %) (room-end c)) (new-behaviors c))]
    (when (and (seq roomy) (>= (- (:end_ns c) (:start_ns c)) (* 2 ms)))
      (let [best (apply min-key :new_in_generation roomy)] ; The latest among equals.
        {:at (clamp-moment c (+ (:vtime_ns best) 1000)) :label (:label best)
         :reached (:new_in_generation best)}))))

(defn- seconds [ns] (/ (Math/round (/ ns 1e7)) 100.0))

(def jev-log-lines 6)

(defn- logs-before
  "The last log lines of each timeline before its moment, from the run's events under serve (one
  SQL call for all of them): {branch [\"node: text\" ...]}, {} without them."
  [run-url pairs]
  (if-not (and (string? run-url) (str/starts-with? run-url "http") (seq pairs))
    {}
    (let [wanted (str/join ", " (for [[branch at] pairs] (format "(%d, %d)" branch at)))
          sql (str "with wanted(branch, moment) as (values " wanted ") " ; `at` is reserved.
                   "select branch, node, text from (select e.branch, e.node, e.text, e.vtime_ns, "
                   "row_number() over (partition by e.branch order by e.vtime_ns desc) as k "
                   "from events e join wanted w on e.branch = w.branch and e.vtime_ns <= w.moment "
                   "where e.text is not null and e.node is not null and e.node <> 'kernel') "
                   "where k <= " jev-log-lines " order by branch, vtime_ns")
          response (try (http/post (str run-url "/sql") {:body (json/generate-string {:sql sql})
                                                        :timeout 20000 :throw false})
                        (catch Exception _ nil))]
      (if (= 200 (:status response))
        (reduce (fn [found {:keys [branch node text]}]
                  (update found branch (fnil conj []) (clip (str node ": " text) 200)))
                {} (json/parse-string (:body response) true))
        {}))))

(defn- troubles
  "Each timeline's last troubled line (ERROR, WARN, panic, fail...) of its nodes within its first
  four fifths, from the run's events (one SQL call): {branch {:at vtime_ns :line text}}, {}
  without them."
  [run-url spans]
  (if-not (and (string? run-url) (str/starts-with? run-url "http") (seq spans))
    {}
    (let [wanted (str/join ", " (for [[branch from to] spans] (format "(%d, %d, %d)" branch from to)))
          sql (str "with wanted(branch, start, stop) as (values " wanted ") "
                   "select branch, vtime_ns, node, text from (select e.branch, e.vtime_ns, e.node, e.text, "
                   "row_number() over (partition by e.branch order by e.vtime_ns desc) as k "
                   "from events e join wanted w on e.branch = w.branch and e.vtime_ns > w.start "
                   "and e.vtime_ns <= w.stop where e.text is not null and e.node is not null "
                   "and e.node <> 'kernel' and (e.text ilike '%error%' or e.text ilike '%warn%' "
                   "or e.text ilike '%panic%' or e.text ilike '%fail%' or e.text ilike '%timeout%' "
                   "or e.text ilike '%refused%')) where k = 1")
          response (try (http/post (str run-url "/sql") {:body (json/generate-string {:sql sql})
                                                        :timeout 20000 :throw false})
                        (catch Exception _ nil))]
      (if (= 200 (:status response))
        (into {} (for [{:keys [branch vtime_ns node text]} (json/parse-string (:body response) true)]
                   [branch {:at vtime_ns :line (clip (str node ": " text) 200)}]))
        {}))))

(defn jev-wide-returns
  "Every timeline of the generation a candidate, Jev ranking them all: each at its rarest new
  behavior that leaves room to go on, else just after its last troubled log line (ERROR, WARN,
  panic, fail...) in its first four fifths; with its last log lines before that moment. Where
  rarity only orders the timelines that reached something new, Jev may send the tree after an
  error no coverage told apart."
  [generation candidates count]
  (let [run @current-run
        spans (for [c candidates :when (>= (- (:end_ns c) (:start_ns c)) (* 2 ms))]
                [(:branch c) (:start_ns c) (room-end c)])
        troubled (troubles run spans)
        offered (->> candidates
                     (keep (fn [c]
                             (or (some-> (rarest-new c) (assoc :c c :why "its rarest new behavior"))
                                 (when-let [{:keys [at line]} (get troubled (:branch c))]
                                   {:c c :at (clamp-moment c (+ at 1000)) :label line :reached 99
                                    :why "its last troubled log line"}))))
                     (take jev-questions-max))
        printed (logs-before run (for [{:keys [c at]} offered] [(:branch c) at]))
        state {:system (jev-context)
               :how (str "A deterministic simulation explores timelines of the system under faults; "
                         "from a moment of a timeline, new timelines continue with other decisions.")
               :generation generation
               :timelines (for [{:keys [c label why]} offered]
                            {:timeline (:branch c) :from_s (seconds (:start_ns c)) :to_s (seconds (:end_ns c))
                             :already_failed (vec (take 6 (:failing (get @ends (:branch c)))))
                             :new_behaviors (for [b (take 12 (new-behaviors c))]
                                              {:behavior (clip (:label b) 120)
                                               :first_reached_by (:new_in_generation b)})
                             :moment_after (str why ": " (clip label 120))
                             :last_logs (get printed (:branch c) [])})
               :recent_failures (->> @ends (sort-by key) (take-last 16)
                                     (keep (fn [[index end]]
                                             (when (seq (:failing end))
                                               {:timeline index :failing (take 6 (:failing end))}))))}
        questions (into {} (for [{:keys [c label]} offered]
                             [(str "t" (:branch c))
                              {:type "noul"
                               :instructions (str "Branching again from timeline " (:branch c)
                                                  " just after '" (clip label 100) "' is likely to "
                                                  "make one of the system's properties fail" jev-anew)}]))
        answers (if (seq offered) (jev-ask state questions) {})]
    (->> offered
         (keep (fn [{:keys [c at label why]}]
                 (when-let [probability (get-in answers [(keyword (str "t" (:branch c))) :noul])]
                   {:score probability :branch (:branch c) :vtime_ns at
                    :reason (format "jev-wide: Jev's probability of a bug %.2f, just after %s (%s)"
                                    (double probability) (clip label 100) why)})))
         (sort-by (comp - :score))
         (take count))))

(defn jev-returns
  "Jev's probability that branching just after each timeline's rarest new behavior finds a bug
  (`:blend`: times its rarity); the likeliest first."
  [generation candidates count & {:keys [blend logs]}]
  (let [offered (->> candidates
                     (keep (fn [c] (when-let [moment (rarest-new c)] (assoc moment :c c))))
                     (sort-by :reached)
                     (take jev-questions-max))
        ;; `:logs`: what each timeline printed last before its moment.
        printed (if logs (logs-before @current-run (for [{:keys [c at]} offered] [(:branch c) at])) {})
        state {:system (jev-context)
               :how (str "A deterministic simulation explores timelines of the system under faults; "
                         "from a moment of a timeline, new timelines continue with other decisions.")
               :generation generation
               :timelines (for [{:keys [c label]} offered]
                            (cond-> {:timeline (:branch c) :from_s (seconds (:start_ns c)) :to_s (seconds (:end_ns c))
                                     :already_failed (vec (take 6 (:failing (get @ends (:branch c)))))
                             :new_behaviors (for [b (take 12 (new-behaviors c))]
                                              {:behavior (clip (:label b) 120)
                                               :first_reached_by (:new_in_generation b)})
                             :rarest_new (clip label 120)}
                              logs (assoc :last_logs (get printed (:branch c) []))))
               :recent_failures (->> @ends (sort-by key) (take-last 16)
                                     (keep (fn [[index end]]
                                             (when (seq (:failing end))
                                               {:timeline index :failing (take 6 (:failing end))}))))}
        questions (into {} (for [{:keys [c label]} offered]
                             [(str "t" (:branch c))
                              {:type "noul"
                               :instructions (str "Branching again from timeline " (:branch c)
                                                  " just after '" (clip label 100) "' is likely to "
                                                  "make one of the system's properties fail" jev-anew)}]))
        answers (if (seq offered) (jev-ask state questions) {})]
    (->> offered
         (keep (fn [{:keys [c at label reached]}]
                 (when-let [probability (get-in answers [(keyword (str "t" (:branch c))) :noul])]
                   (let [score (if blend (/ probability reached) probability)]
                     {:score score :reached reached :branch (:branch c) :vtime_ns at
                      :reason (format "%s %.2f, just after %s"
                                      (if blend "jev-blend: rarity times Jev's probability"
                                          "jev: Jev's probability of a bug")
                                      (double score) label)}))))
         (sort-by (juxt (comp - :score) :reached))
         (take count))))

;; `:jev-archive` is the explorer's whole rule with Jev ranking inside each half: the frontier's
;; moments by rarity times Jev's probability (`:jev-blend`), the archive's offered cells by Jev's
;; probability over the explorer's own rank of them ((1 + timelines) (1 + returns) / (1 + paid)).
;; Without an archive offered (explorers before it), it is `:jev-blend`.

(defn failed-timeline?
  "Whether a timeline failed a property (its branch_end said so): a child returned into it fails
  it too and finds nothing new (raft A/B 2026-11-07: jev-wide's 69 failing returns, 11 new; the
  explorer's 22 all new)."
  [branch]
  (boolean (seq (:failing (get @ends branch)))))

(defn jev-archive-returns
  [generation candidates count]
  (let [frontier (jev-returns generation (remove #(failed-timeline? (:branch %)) candidates) count :blend true)
        kept (if (seq *archive*) (take (quot (inc count) 2) frontier) frontier)
        wanted (- count (clojure.core/count kept))
        cells (vec (take jev-questions-max *archive*))]
    (if (or (zero? wanted) (empty? cells))
      kept
      (let [state {:system (jev-context)
                   :how (str "A deterministic simulation explores timelines of the system under faults; "
                             "from a moment of a timeline, new timelines continue with other decisions. "
                             "An archive keeps earlier moments, each just after a behavior few timelines reached.")
                   :generation generation
                   :archive (for [[index cell] (map-indexed vector cells)]
                              {:moment index :timeline (:branch cell) :at_s (seconds (:vtime_ns cell))
                               :just_after (clip (:label cell) 120) :timelines_reached (:timelines cell)
                               :returned_to (:returns cell) :returns_finding_new (:paid cell)})
                   :recent_failures (->> @ends (sort-by key) (take-last 16)
                                         (keep (fn [[index end]]
                                                 (when (seq (:failing end))
                                                   {:timeline index :failing (take 6 (:failing end))}))))}
            questions (into {} (for [[index cell] (map-indexed vector cells)]
                                 [(str "m" index)
                                  {:type "noul"
                                   :instructions (str "Branching again from timeline " (:branch cell)
                                                      " just after '" (clip (:label cell) 100) "' is likely to "
                                                      "make one of the system's properties fail" jev-anew)}]))
            answers (jev-ask state questions)
            taken (set (map (juxt :branch :vtime_ns) kept))]
        (->> cells
             (map-indexed
              (fn [index cell]
                (when-let [probability (get-in answers [(keyword (str "m" index)) :noul])]
                  (let [rank (/ (* (inc (:timelines cell)) (inc (:returns cell))) (inc (:paid cell)))]
                    {:score (/ probability rank) :branch (:branch cell) :vtime_ns (:vtime_ns cell)
                     :reason (format "jev-archive: Jev's probability %.2f over the archive's rank %.1f, just after %s"
                                     (double probability) (double rank) (clip (:label cell) 80))}))))
             (remove nil?)
             (remove #(taken [(:branch %) (:vtime_ns %)]))
             (sort-by (comp - :score))
             (take wanted)
             (concat kept))))))

;; `:jev-faults` weights named decisions (`fault`, the SDKs' `decide`): every `jev-every`
;; timelines, one call with a "choice" per decision among its options, from what recent timelines
;; were given (their faults) and what failed in them; Jev's probabilities then weight the draws
;; until the next call, a quarter of them (`jev-keep`) left to the default so timelines still
;; differ. It is asked only for named decisions and told only assertions and faults (its hello's
;; "labeled" and "assertions"): a round trip per decision, not per pull. The assertions it is
;; told of are the system's properties in Jev's state. The call runs beside the exploration (a
;; future): no decision waits for it.

(defonce jev-weights (atom {}))    ; decision name -> {option index probability}
(defonce jev-options (atom {}))    ; decision name -> its options, as last seen
(defonce jev-properties (atom {})) ; assertion message -> its kind
(defonce jev-history (atom []))    ; recent timelines: {:faults :failing}
(def jev-every 8)
(def jev-keep 0.25)
(def jev-options-max 48)

(defn- jev-described []
  (let [kinds @jev-properties
        safety (for [[message kind] kinds :when (#{"always" "unreachable"} kind)] message)
        targets (for [[message kind] kinds :when (not (#{"always" "unreachable"} kind))] message)]
    (cond-> (jev-context)
      (seq safety) (update :properties_a_bug_makes_false #(or % (vec (take 48 safety))))
      (seq targets) (update :targets_not_reached_yet #(or % (vec (take 48 targets)))))))

(defn jev-consult!
  "One call: a choice per named decision seen, its probabilities the draws' weights."
  []
  (let [decisions (vec (take jev-questions-max
                             (for [[decision options] @jev-options
                                   :when (< 1 (count options) (inc jev-options-max))]
                               decision)))
        state (assoc (jev-described)
                     :how (str "A deterministic simulation injects faults into the system; each "
                               "timeline is given faults, and properties are checked. Recent "
                               "timelines, their faults and the properties that failed in them:")
                     :recent_timelines (vec (take-last 16 @jev-history)))
        questions (into {} (for [[number decision] (map-indexed vector decisions)]
                             [(str "d" number)
                              {:type "choice"
                               :instructions (str "For the decision '" decision "', the option most likely "
                                                  "to make a property fail next (try what recent "
                                                  "timelines did not, when they found nothing)")
                               :criteria (into {} (map-indexed (fn [i option] [(str "o" i) (clip (str option) 100)])
                                                               (get @jev-options decision)))}]))
        answers (if (seq decisions) (jev-ask state questions) {})]
    (doseq [[number decision] (map-indexed vector decisions)
            :let [probabilities (get-in answers [(keyword (str "d" number)) :probabilities])
                  weights (into {} (for [[option p] probabilities
                                         :let [index (parse-long (subs (name option) 1))]
                                         :when index]
                                     [index (double p)]))]
            :when (seq weights)]
      (swap! jev-weights assoc decision weights))))

(defn jev-faults-decide [state {:keys [decision size default]}]
  (let [{label :name options :options} decision]
    (when (seq options)
      (swap! jev-options assoc label options)
      (let [weights (get @jev-weights label)
            weights (when weights (filter (fn [[index _]] (< index (count options))) weights))
            chosen (when (and (seq weights) (>= (rand) jev-keep))
                     (let [total (reduce + (map second weights))
                           target (* (rand) total)]
                       (loop [[[index weight] & more] weights sum 0.0]
                         (if (or (nil? more) (< target (+ sum weight))) index (recur more (+ sum weight))))))]
        (when (= "fault" label)
          (let [index (or chosen (mod (reduce + (map-indexed (fn [i b] (bit-shift-left b (* 8 i)))
                                                             (map #(Integer/parseInt (apply str %) 16)
                                                                  (partition 2 default))))
                                      (count options)))]
            (swap! state update :faults (fnil conj []) (nth options index))))
        (when chosen
          {:hex (index-hex chosen size)
           :reason (format "jev-faults: Jev weighted %s at %.2f" (clip (str (nth options chosen)) 60)
                           (double (get (into {} weights) chosen)))})))))

(defn jev-faults-event [_state {:keys [event]}]
  (when-let [assertion (or (:assert event) (:antithesis_assert event))]
    (let [message (:message assertion)]
      (when (and (string? message) (< (count @jev-properties) 48))
        (swap! jev-properties assoc (clip message 160)
               (or (:type assertion) (:assert_type assertion) ""))))))

(defn jev-faults-end [state {:keys [failing]}]
  (let [history (swap! jev-history #(vec (take-last 32 (conj % {:faults (vec (take 12 (:faults @state)))
                                                                :failing (vec (take 6 failing))}))))]
    (when (zero? (mod (count @ends) jev-every))
      (future (try (jev-consult!)
                   (catch Exception e (binding [*out* *err*] (println "jev-faults:" (ex-message e)))))))
    history))

;; `:jev-follow` follows each timeline beside it, never stopping it: Jev plans, the timeline
;; goes on, Jev looks at what happened and plans again. A timeline's named decisions (`fault`, the
;; workload's `decide`) are drawn from its current plan (Jev's probabilities per decision), or
;; left to their defaults until it has one; on news in its story (a fault, a failed assertion)
;; or every `jev-follow-every-ns` of virtual time, one call in the background plans again from
;; that timeline's own story (a branch starts from its parent's story up to its moment). The
;; draws it changes are in the tapes at the pull they reached, so every timeline replays exactly
;; whenever Jev answered; an answer for a timeline already over is dropped. Its returns are the
;; explorer's whole rule (`rarity`).

(def jev-follow-story-max 24)
(def jev-follow-every-ns (* 10 1000 1000000))
;; News (a fault, a failure) asks again only this long after the last plan (virtual time), and
;; at most `jev-follow-in-flight-max` plans are asked at once on this host: re-planning at every
;; fault asked Jev 1823 times in 15 minutes for two workers (the council's planning test).
(def jev-follow-news-min-ns (* 2 1000 1000000))
(def jev-follow-in-flight-max 8)
(defonce jev-follow-in-flight (atom 0))
(defonce jev-stories (atom {})) ; Branch -> its story at its end (the last 512), for its children.
;; How much Jev steered (since the run began): plans asked and made, draws its plans decided,
;; draws left to their defaults (no plan yet), plans that arrived after their timeline ended.
(defonce jev-follow-stats (atom {:asked 0 :planned 0 :steered 0 :defaulted 0 :late 0}))
(defonce jev-follow-by-run (atom {})) ; A run (its run_url) -> its stats, kept as the next begins.
;; The code lines any timeline of the run reached (its live coverage events): a line a timeline
;; reaches first goes into its story (`:reached`), context for its next plan, not news.
(defonce jev-code-seen (atom #{}))
(def jev-code-seen-max 200000)
(defn- jev-follow-count! [k] (swap! jev-follow-stats update k (fnil inc 0))) ; A reset to {} as well.

(defn- story-note [state entry]
  (swap! state update :story #(vec (take-last jev-follow-story-max (conj (or % []) entry)))))

(defn jev-follow-start [state {:keys [index from]}]
  (swap! state assoc :index index :plan {} :options {} :planning false :planned_ns nil :planned_story 0
         :story (if from
                  (vec (filter #(<= (:at_ns %) (:vtime_ns from)) (get @jev-stories (:branch from))))
                  [])))

(defn- news-count [story] (count (remove #(or (:chose %) (:reached %)) story)))

(defn- jev-follow-plan!
  "One call in the background: a choice per decision the timeline has drawn, from its story; the
  plan replaces the timeline's own if it is still the one asked for."
  [state vtime_ns]
  (let [{:keys [index story options]} @state
        decisions (vec (take jev-questions-max (for [[label opts] options :when (< 1 (count opts) (inc jev-options-max))] label)))]
    (when (and (seq decisions) (< @jev-follow-in-flight jev-follow-in-flight-max))
      (swap! jev-follow-in-flight inc)
      (swap! state assoc :planning true :planned_ns vtime_ns :planned_story (news-count story))
      (jev-follow-count! :asked)
      (future
        (try
          (let [answers (jev-ask (assoc (jev-described)
                                        :how (str "A deterministic simulation injects faults into the system, "
                                                  "one timeline at a time; this timeline's own story so far (faults "
                                                  "injected, properties that failed, choices made, seconds of "
                                                  "virtual time). The timeline goes on while you answer.")
                                        :timeline {:at_s (seconds vtime_ns)
                                                   :story (vec (for [entry story]
                                                                 (-> entry (dissoc :at_ns) (assoc :at_s (seconds (:at_ns entry))))))})
                                 (into {} (for [[number label] (map-indexed vector decisions)]
                                            [(str "d" number)
                                             {:type "choice"
                                              :instructions (str "For this timeline's next '" label "' decisions"
                                                                 (when-let [meaning (timing-decisions label)] (str " (" meaning ")"))
                                                                 ", the option most likely to make one of the system's "
                                                                 "properties fail" jev-anew ", given its story")
                                              :criteria (into {} (map-indexed (fn [i option] [(str "o" i) (clip (str option) 100)])
                                                                              (get options label)))}])))
                plan (into {} (for [[number label] (map-indexed vector decisions)
                                    :let [weights (into {} (for [[option p] (get-in answers [(keyword (str "d" number)) :probabilities])
                                                                 :let [i (parse-long (subs (name option) 1))]
                                                                 :when (and i (< i (count (get options label))))]
                                                             [i (double p)]))]
                                    :when (seq weights)]
                                [label weights]))]
            (if (= index (:index @state)) (jev-follow-count! :planned) (jev-follow-count! :late))
            (swap! state (fn [now] (if (= index (:index now)) (assoc now :plan plan :planning false) now))))
          (catch Exception e
            (jev-follow-count! :failed) ; Said in the A/B's report: a throttled Jev plans nothing.
            (swap! state (fn [now] (if (= index (:index now)) (assoc now :planning false) now)))
            (binding [*out* *err*] (println "jev-follow:" (ex-message e))))
          (finally (swap! jev-follow-in-flight dec)))))))

(defn jev-follow-event [state {:keys [vtime_ns event] :as request}]
  (jev-faults-event state request) ; The properties, for Jev's description of the system.
  (when vtime_ns (swap! state assoc :now vtime_ns))
  (let [assertion (or (:assert event) (:antithesis_assert event))]
    (cond
      ;; A decision announced (a planning strategy is told them): its options, or a timing
      ;; draw's thirds, for the next plan.
      (map? (:decision event))
      (let [{label :name options :options span :range} (:decision event)]
        (cond
          (and (timing-decisions label) (integer? span) (>= span 3))
          (swap! state #(-> % (assoc-in [:options label] (mapv :text (timing-options label span)))
                            (assoc-in [:spans label] span)))
          (and (string? label) (< 1 (count options) (inc jev-options-max)))
          (swap! state assoc-in [:options label] options)))
      ;; What its plan drew: the timeline's own choice, in its story (the council credits it).
      (= "planned" (:event event))
      (let [_ (jev-follow-count! :drawn)
            {:keys [value decision]} (:details event)
            label (:name decision)
            text (if-let [span (get-in @state [:spans label])]
                   (some (fn [{:keys [low high text]}] (when (and (<= low value) (< value high)) (str label " " text)))
                         (timing-options label span))
                   (when (= "fault" label) (get (get-in @state [:options label]) value)))]
        (when text (story-note state {:at_ns vtime_ns :chose (clip (str text) 80)})))
      (= "coverage" (:event event))
      (let [line (str (:name (:details event)))]
        (when (and (seq line) (not (contains? @jev-code-seen line)) (< (count @jev-code-seen) jev-code-seen-max))
          (swap! jev-code-seen conj line)
          (story-note state {:at_ns vtime_ns :reached (clip line 100)})))
      (= "fault" (:event event))
      (let [{:keys [kind node]} (:details event)]
        (story-note state {:at_ns vtime_ns :fault (clip (str kind (when (seq node) (str " " node))) 60)}))
      (and assertion (false? (:condition assertion)) (not (false? (:hit assertion)))
           (#{"always" "always_or_unreachable"} (or (:type assertion) (:assert_type assertion))))
      (story-note state {:at_ns vtime_ns :failed (clip (str (:message assertion)) 120)}))))

;; When faults come is a decision too: the fault injector's timing draws (named, over a range) are
;; offered as three choices, the short, middle and long thirds of the range in seconds, so Jev can
;; plan to wait and watch, or press on; the value drawn uniformly inside the third chosen (even
;; weights: the injector's own uniform draw).
(def timing-decisions
  {"fault.wait_ns" "the wait before the next fault, beyond its least"
   "fault.quiet_ms" "the quiet pause between bursts of faults, beyond its least"
   "fault.active_ms" "how long the next burst of faults lasts, beyond its least"
   "fault.duration_ns" "how long the fault being injected lasts"})

(defn timing-options
  "A timing draw's choices: [{:text :low :high}] over [0, span), in the draw's unit."
  [label span]
  (let [per-second (if (str/ends-with? label "_ns") 1e9 1e3)
        cut (fn [k] (long (quot (* k span) 3)))
        s (fn [v] (format "%.1f s" (/ (double v) per-second)))]
    [{:text (str "short (under " (s (cut 1)) ")") :low 0 :high (cut 1)}
     {:text (str "middle (" (s (cut 1)) " to " (s (cut 2)) ")") :low (cut 1) :high (cut 2)}
     {:text (str "long (over " (s (cut 2)) ")") :low (cut 2) :high span}]))

(defn decision-kind
  "The kind of a named decision's option, as records credit it: a fault by its option alone,
  other decisions with their name (a timing third: 'fault.quiet_ms long (over # s)')."
  [label option]
  (moment-kind (if (= "fault" label) (str option) (str label " " option))))

(defn jev-follow-decide
  "`adjust` (label options weights) -> weights reweighs the plan (the council's learned payoffs
  and Claude's boosts); with it a draw before Jev's first plan starts from even weights."
  [state {:keys [decision size vtime_ns]} & {:keys [adjust prefix] :or {prefix "jev-follow"}}]
  (let [{label :name options :options span :range} decision
        timing (when (and (timing-decisions label) (integer? span) (>= span 3))
                 (timing-options label span))
        options (if timing (mapv :text timing) options)]
    (when (and (string? label) (< 1 (count options) (inc jev-options-max)))
      (swap! state assoc-in [:options label] options)
      (let [{:keys [plan planning planned_ns planned_story story]} @state]
        ;; Plan again in the background on news, or in time; this draw never waits for it.
        (when (and (not planning)
                   (or (nil? planned_ns) (not= planned_story (news-count story))
                       (>= (- vtime_ns planned_ns) jev-follow-every-ns)))
          (jev-follow-plan! state vtime_ns))
        (when-not (seq (get plan label)) (jev-follow-count! :defaulted))
        (when-let [weights (if adjust
                             (seq (adjust label options (or (not-empty (get plan label))
                                                            (zipmap (range (count options)) (repeat 1.0)))))
                             (seq (get plan label)))]
          (jev-follow-count! :steered)
          (let [total (reduce + (map second weights))
                target (* (rand) total)
                chosen (loop [[[index weight] & more] (sort weights) sum 0.0]
                         (if (or (nil? more) (< target (+ sum weight))) index (recur more (+ sum weight))))]
            (when (or (= "fault" label) timing)
              (story-note state {:at_ns vtime_ns
                                 :chose (clip (if timing (str label " " (nth options chosen)) (str (nth options chosen))) 80)}))
            {:hex (if timing
                    (let [{:keys [low high]} (nth timing chosen)]
                      (index-hex (+ low (long (rand (max 1 (- high low))))) size))
                    (index-hex chosen size))
             :reason (format "%s: plan %.2f for %s %s" prefix
                             (double (/ (get (into {} weights) chosen) (max total 1e-9))) label
                             (clip (str (nth options chosen)) 60))}))))))

(declare council-weights-adjust)

(defn decision-plan
  "A planning strategy's plan (its reply to a batch): per decision seen, Jev's weights (adjusted
  by `adjust`, the council's), as segments of the decision's values: an option's index, a timing
  third's range. Asks Jev again in the background on news or in time, as a decision would."
  [state & {:keys [adjust]}]
  (let [{:keys [plan planning planned_ns planned_story story options spans now]} @state
        now (or now 0)]
    (when (and (seq options) (not planning)
               (or (nil? planned_ns)
                   (and (not= planned_story (news-count story)) (>= (- now planned_ns) jev-follow-news-min-ns))
                   (>= (- now planned_ns) jev-follow-every-ns)))
      (jev-follow-plan! state now))
    (not-empty
     (into {} (for [[label opts] options
                    :let [base (or (not-empty (get plan label)) (when adjust (zipmap (range (count opts)) (repeat 1.0))))
                          weights (if (and adjust base) (adjust label opts base) base)
                          span (get spans label)
                          thirds (when span (timing-options label span))]
                    :when (seq weights)]
                [label (vec (for [[i w] (sort weights)
                                  :when (< i (count opts))]
                              (if thirds
                                (let [{:keys [low high]} (nth thirds i)] [low high (double w)])
                                [i (inc i) (double w)])))])))))

(defn- jev-follow-moments
  "A timeline's moments worth branching from, as its own instance sees them: just after each
  behavior it reached first (its coverage, new to the generation), each fault it was given and
  each failure, within the part of it that leaves room to go on; the last `jev-options-max`."
  [c story]
  (let [end (room-end c)
        behaviors (for [b (new-behaviors c) :when (<= (:vtime_ns b) end)]
                    {:at (clamp-moment c (+ (:vtime_ns b) 1000))
                     :what (str "just after it first reached " (clip (:label b) 90)
                                " (" (:new_in_generation b) " timelines reached it)")})
        told (for [entry story :when (and (> (:at_ns entry) (:start_ns c)) (<= (:at_ns entry) end)
                                          (or (:fault entry) (:failed entry)))]
               {:at (clamp-moment c (+ (:at_ns entry) 1000))
                :what (if (:fault entry) (str "just after the fault " (:fault entry))
                          (str "just after it failed " (:failed entry)))})]
    (->> (concat behaviors told) (sort-by :at) (take-last jev-options-max) vec)))

(defn jev-follow-returns
  "Each timeline's own instance names the moment of it to branch from (one choice question per
  timeline, from its story and the coverage it reached first, in one call); the generation
  follows the most confident half of them, never into a timeline that failed, and the explorer's
  archive for the rest (all of them without an archive offered)."
  [generation candidates count]
  (let [offered (vec (for [c candidates
                           :when (not (failed-timeline? (:branch c)))
                           :let [moments (jev-follow-moments c (get @jev-stories (:branch c)))]
                           :when (seq moments)]
                       {:c c :moments moments}))
        answers (if (seq offered)
                  (jev-ask (assoc (jev-described)
                                  :how (str "A deterministic simulation explores timelines of the system under "
                                            "faults; from a moment of a timeline, new timelines continue with "
                                            "other decisions. Each timeline below, its own story (faults, failures, "
                                            "seconds of virtual time) and the moments it could branch from.")
                                  :generation generation
                                  :timelines (for [{:keys [c]} offered]
                                               {:timeline (:branch c)
                                                :already_failed (vec (take 6 (:failing (get @ends (:branch c)))))
                                                :story (vec (for [entry (get @jev-stories (:branch c))]
                                                              (-> entry (dissoc :at_ns) (assoc :at_s (seconds (:at_ns entry))))))}))
                           (into {} (for [{:keys [c moments]} offered]
                                      [(str "t" (:branch c))
                                       {:type "choice"
                                        :instructions (str "The moment of timeline " (:branch c) " to branch new "
                                                           "timelines from, most likely to lead to one of the "
                                                           "system's properties failing" jev-anew)
                                        :criteria (into {} (map-indexed (fn [i m] [(str "o" i) (clip (:what m) 120)])
                                                                        moments))}])))
                  {})
        nominated (->> offered
                       (keep (fn [{:keys [c moments]}]
                               (when-let [probabilities (seq (get-in answers [(keyword (str "t" (:branch c))) :probabilities]))]
                                 (let [[option p] (apply max-key (comp double second) probabilities)
                                       index (parse-long (subs (name option) 1))]
                                   (when (and index (< index (clojure.core/count moments)))
                                     (let [m (nth moments index)]
                                       {:score (double p) :branch (:branch c) :vtime_ns (:at m)
                                        :reason (format "jev-follow: timeline %d's own pick %.2f, %s"
                                                        (:branch c) (double p) (:what m))}))))))
                       (sort-by (comp - :score)))
        kept (if (seq *archive*) (take (quot (inc count) 2) nominated) (take count nominated))]
    (if (empty? kept)
      (rarity generation candidates count)
      (concat kept (archive-returns (- count (clojure.core/count kept)))))))

(defn jev-follow-end [state {:keys [index]}]
  (swap! jev-stories (fn [stories]
                       (let [stories (assoc stories index (:story @state))]
                         (if (> (count stories) 512) (into {} (take-last 512 (sort-by key stories))) stories)))))

;; Go-Explore's archive, with the cell pluggable: every cell any timeline of any generation
;; reached, where (just after the first timeline reached it), how many timelines reached it and
;; how often it was returned to. `cell-of` makes a behavior a cell: redefine it from the REPL
;; (coarser: `(defn cell-of [b] (str/replace (:label b) #"\d+" "N"))`, or by what a domain
;; cares about) and the next generation uses it. `(reset! archive {})` starts over.
(defonce archive (atom {})) ; cell -> {:branch :vtime_ns :label :reached :returns}

(defn cell-of
  "A behavior's cell: its label (the explorer's own notion, each behavior a cell)."
  [behavior]
  (:label behavior))

(defn- archive-note! [candidates]
  (doseq [c candidates
          b (:behaviors c)
          :when (<= (:vtime_ns b) (room-end c))
          :let [cell (cell-of b)]
          :when cell]
    (swap! archive update cell
           (fn [known]
             (if known
               (update known :reached inc)
               {:branch (:branch c) :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000))
                :label (:label b) :reached 1 :returns 0})))))

(defn archived
  "Half the returns to the archive's least explored cells (score (1 + reached) * (1 + returns):
  rare, seldom returned to), from any generation; the rest to this generation's rarest new
  behaviors (rarity). All to the archive when nothing is new."
  [generation candidates count]
  (archive-note! candidates)
  (let [fresh (vec (rarity generation candidates count))
        wanted (if (seq fresh) (quot (inc count) 2) count)
        cells (->> @archive
                   (sort-by (fn [[_ {:keys [reached returns]}]] (* (inc reached) (inc returns))))
                   (take wanted))
        from-archive (for [[cell {:keys [branch vtime_ns label reached returns]}] cells]
                       (do (swap! archive update-in [cell :returns] inc)
                           {:branch branch :vtime_ns vtime_ns
                            :reason (str "archive: " label " (cell " cell "), reached by " reached
                                         " timelines, returned to " returns " times")}))]
    (vec (take count (concat (doall from-archive) fresh)))))

;; Fault schedules (nemeses): a strategy with `:decide` is asked for every named decision of the
;; timeline and told its events (it then says "decides": true at hello: a round trip per
;; decision). `leader-faults` follows the Raft leader in the logs and, when the fault injector
;; draws a fault, picks one aimed at the leader most of the time, as Jepsen's nemeses partition or
;; pause the leader: the moments a cluster is most fragile. Its state is per connection (each
;; exploration worker runs its timelines one at a time).

(defn- index-hex
  "An option's index as the decision's bytes: little endian, `size` bytes."
  [index size]
  (apply str (for [i (range size)] (format "%02x" (bit-and (bit-shift-right index (* 8 i)) 0xff)))))

(defn leader-faults-event [state {:keys [event]}]
  (when-let [text (get-in event [:output :text])]
    (when-let [[_ node] (re-find #"(node-\d+): entering leader state" text)]
      (swap! state assoc :leader node))
    (when (re-find #"entering (follower|candidate) state" text)
      (when-let [[_ node] (re-find #"(node-\d+): entering" text)]
        (when (= node (:leader @state)) (swap! state dissoc :leader))))))

(defn leader-faults-decide
  "A fault aimed at the leader (an option naming its container), seven times in ten; the
  injector's own draw otherwise."
  [state {:keys [decision size]}]
  (let [leader (:leader @state)
        options (:options decision)]
    (when (and leader (= "fault" (:name decision)) (< (rand) 0.7))
      (let [aimed (keep-indexed (fn [i option] (when (str/includes? option (str "raft-" leader)) i)) options)]
        (when (seq aimed)
          (let [index (rand-nth aimed)]
            {:hex (index-hex index size)
             :reason (str "nemesis: " (nth options index) ", at the leader (" leader ")")}))))))

;; Built in, merged at every load (a reload adds or updates them; ones made at the REPL stay).
(def end-timeline
  "What a strategy's :event fn returns to end the timeline at that moment (the explorer stops it
  there: outcome strategy_ended, its end's checks not run, not extended)."
  ::end-timeline)

(defonce strategies (atom {}))
(swap! strategies merge
       {:explorer {:returns (fn [& _] nil)} ; The explorer's built-in choice (a baseline).
         :rarity {:returns #'rarity}
         :rarity-archive2 {:returns #'rarity-archive2}
         :rarest-ever {:returns #'rarest-ever}
         :uniform {:returns #'uniform}
         :deepest {:returns #'deepest}
         :archive {:returns #'archived}
         :jev {:returns #'jev-returns}
         :jev-faults {:returns (fn [& _] nil) :decide #'jev-faults-decide :event #'jev-faults-event
                      :end #'jev-faults-end :wants ["behaviors" "labeled" "assertions"]}
         :jev-blend {:returns (fn [generation candidates count]
                                (jev-returns generation candidates count :blend true))}
         :jev-wide {:returns #'jev-wide-returns}
         :jev-archive {:returns #'jev-archive-returns}
         :jev-follow {:returns #'jev-follow-returns :decide #'jev-follow-decide :event #'jev-follow-event
                      :branch #'jev-follow-start :end #'jev-follow-end
                      :plan (fn [state] (decision-plan state))
                      :wants ["behaviors" "labeled" "assertions" "coverage" "batched" "plans"]}
         :jev-logs {:returns (fn [generation candidates count]
                               (jev-returns generation candidates count :logs true))}
         :jev-blend-logs {:returns (fn [generation candidates count]
                                     (jev-returns generation candidates count :blend true :logs true))}
         :leader-faults {:returns (fn [& _] nil) :decide #'leader-faults-decide :event #'leader-faults-event}
         :adaptive {:returns (fn [generation candidates count] (adaptive-returns generation candidates count))}
         :evolve {:returns (fn [generation candidates count] (evolve-returns generation candidates count))}
         :learn {:returns (fn [generation candidates count] (learn-returns generation candidates count))
                 :end (fn [state request] (learn-end state request))
                 :wants ["behaviors" "labeled" "assertions"]}
         :mix {:returns (fn [generation candidates count] (mix-returns generation candidates count))
               :end (fn [state request] (mix-end state request))
               :wants ["behaviors" "labeled" "assertions"]}
         :council-ender {:returns (fn [generation candidates count] (council-returns generation candidates count))
                         :decide (fn [state request] (council-decide state request))
                         :event (fn [state request] (council-ender-event state request))
                         :branch (fn [state request] (jev-follow-start state request) (swap! state dissoc :failed_names :failed_at))
                         :end (fn [state request] (council-end state request))
                         :plan (fn [state] (decision-plan state :adjust council-weights-adjust))
                         :wants ["behaviors" "labeled" "assertions" "coverage" "batched" "plans"]}
         :council {:returns (fn [generation candidates count] (council-returns generation candidates count))
                   :decide (fn [state request] (council-decide state request))
                   :event (fn [state request] (jev-follow-event state request))
                   :branch (fn [state request] (jev-follow-start state request))
                   :end (fn [state request] (council-end state request))
                   :plan (fn [state] (decision-plan state :adjust council-weights-adjust))
                   :wants ["behaviors" "labeled" "assertions" "coverage" "batched" "plans"]}})

(defonce current (atom :rarity))

;; A port can serve one strategy whatever `current` says (`serve-strategy!`, --strategy-ports):
;; an A/B's arms, each run naming its port, need no control step between them.
(def ^:dynamic *pinned* nil)

(defn strategy-name [] (or *pinned* @current))

;; What the strategies remember belongs to one run: a hello from another (its run_url under
;; serve, else its strategy and exploration seed) starts afresh, so one arm's outcomes never
;; reach the next one's Jev state.
(defonce current-run (atom nil))

(defn- run-started! [request]
  (let [run (or (:run_url request) [(strategy-name) (:exploration_seed request)])]
    ;; A hello whose run_url is no URL is a probe (a port checked by hand): it leaves the run's
    ;; state alone (probes mid-run reset a Jev arm's memory before this).
    (when (and (not= run @current-run)
               (not (and (string? run) (not (str/starts-with? run "http")))))
      (when (pos? (:asked @jev-follow-stats 0)) ; The run ending: what Jev steered in it.
        (swap! jev-follow-by-run assoc @current-run @jev-follow-stats))
      (reset! current-run run)
      (reset! ends {}) (reset! starts {}) (reset! archive {})
      (reset! jev-weights {}) (reset! jev-options {}) (reset! jev-properties {})
      (reset! jev-history [])
      (reset! jev-stories {})
      (reset! jev-code-seen #{})
      (reset! learn-chosen {}) ; This run's moments; what was learned stays.
      (reset! mix-chosen {})
      (reset! run-failed #{})
      (reset! jev-follow-stats {:asked 0 :planned 0 :steered 0 :defaulted 0 :late 0})
      ;; The adaptive strategy's run under serve: Claude advises it every `advise-minutes`.
      (when (and (= :adaptive (strategy-name)) (string? run) (str/starts-with? run "http"))
        (advise-every! run advise-minutes))
      ;; The evolving one's (alone or in the mix): Claude rewrites it every `evolve-minutes`.
      (when (and (#{:evolve :mix} (strategy-name)) (string? run) (str/starts-with? run "http"))
        (evolve-every! run evolve-minutes))
      ;; The council's: Claude reviews and tunes it every `council-review-minutes`.
      (when (and (#{:council :council-ender} (strategy-name)) (string? run) (str/starts-with? run "http"))
        (council-review-every! run council-review-minutes)))))

(defn use-strategy! [name]
  (assert (contains? @strategies name) (str "no strategy " name))
  (reset! current name))

;; The slow loop: Claude reads a run and chooses its strategy -------------------------------------
;; `:adaptive` returns as `adaptive-choice` says (a strategy's name). `(advise! run-url)` shows
;; Claude (the `claude` command line, logged in where this host runs) the run's properties with
;; their finds, what the last generations chose and why, and Jev's call counts; Claude answers
;; which strategy to use next and, if it can say better, what the system is for Jev. Every advice is
;; kept in `@advice`. `(advise-every! run-url 10)` asks again every 10 minutes while the run lives
;; (`(stop-advising!)` ends it). A strategy run's choices are in its tapes, so its replays need
;; neither Claude nor Jev.

(defonce adaptive-choice (atom :rarity))
(defonce advice (atom []))     ; [{:run :at :asked :answer :applied}]
(defonce advising (atom nil))  ; The loop's future.
(def advisor-model "claude-sonnet-5-5")

(defn adaptive-returns [generation candidates count]
  (let [choice @adaptive-choice
        f (:returns (get @strategies choice))]
    (if (and f (not= choice :adaptive)) (f generation candidates count) nil)))

(defn- system-key [run] (str/replace (or (:system run) "") #"^[0-9a-f]{16}-" ""))

;; Strategies by the port a run's request names (`tcp://127.0.0.1:<port>`, the host's ports as
;; the runs' host reaches them through tunnels); an upload by its name; none: the explorer's own.
(defonce remote-strategy-ports
  (atom {9110 "rarity" 9111 "jev" 9112 "jev-blend" 9113 "jev-faults" 9114 "jev-blend-logs" 9115 "adaptive"
         9116 "jev-wide" 9117 "claude-2" 9118 "rarity-archive2" 9119 "jev-archive" 9120 "jev-follow"
         9121 "evolve" 9122 "learn" 9123 "mix" 9124 "council" 9125 "council-ender"}))

(defn- strategy-label [request]
  (let [strategy (:strategy request)]
    (cond (nil? strategy) "explorer"
          (str/starts-with? strategy "@") (subs strategy 1)
          :else (or (some->> (re-find #":(\d+)$" strategy) second parse-long (get @remote-strategy-ports))
                    strategy))))

;; A strategy's own skill: the timelines it returned to, how many failed a property anew (one the
;; timeline returned to never failed: a child of one headed for a failure fails it too and finds
;; nothing, jev-wide's run 1360), and their CPU-hours; the explorer's returns when it runs alone.
;; As ab.py's origins and serve's Where failures came from.
(def ^:private failing-sql
  (str "((kind = 'assert' AND coalesce(json_extract(event, '$.assert.hit')::BOOLEAN, true) AND "
       "((type IN ('always', 'always_or_unreachable') AND condition = false) OR "
       "(type = 'unreachable' AND condition = true))) OR (kind = 'antithesis_assert' AND "
       "coalesce(json_extract(event, '$.antithesis_assert.hit')::BOOLEAN, false) AND "
       "(type = 'unreachable' OR (type IN ('always', 'always_or_unreachable') AND condition = false))))"))

(defn- run-chosen [run-url plugin?]
  (let [chosen (if plugin? "why LIKE 'The strategy returned%'"
                   "coalesce(why, '') <> '' AND why NOT LIKE 'From the setup snapshot%'")
        sql (str "WITH failed AS (SELECT DISTINCT branch, name FROM events WHERE branch IS NOT NULL AND "
                 failing-sql "), c AS (SELECT branch, parent, wall_ns FROM timelines WHERE " chosen "), "
                 "j AS (SELECT c.branch, bool_or(f.name IS NOT NULL AND p.branch IS NULL) AS anew "
                 "FROM c LEFT JOIN failed f USING (branch) "
                 "LEFT JOIN failed p ON p.branch = c.parent AND p.name = f.name GROUP BY c.branch) "
                 "SELECT count(*) AS timelines, count(*) FILTER (WHERE anew) AS failing_anew, "
                 "sum(wall_ns) AS wall_ns FROM c JOIN j USING (branch)")
        response (try (http/post (str run-url "/sql") {:body (json/generate-string {:sql sql})
                                                      :timeout 120000 :throw false})
                      (catch Exception _ nil))]
    (when (= 200 (:status response))
      (let [row (first (json/parse-string (:body response) true))]
        {:timelines (or (:timelines row) 0) :failing_anew (or (:failing_anew row) 0)
         :cpu_hours (/ (or (:wall_ns row) 0) 3.6e12)}))))

(defonce run-summaries (atom {})) ; A finished run's id -> its summary (it never changes).

(defn- run-summary [base id]
  (or (get @run-summaries id)
      (let [run (http-json (str base "/runs/" id) :timeout 60000)
            properties (http-json (str base "/runs/" id "/properties") :timeout 60000)
            label (strategy-label (:request run))
            summary {:strategy label
                     :compose (:compose (:request run))
                     :chosen (run-chosen (str base "/runs/" id) (not= "explorer" label))
                     :cpu_hours (/ (or (:wall_ns (:stats run)) 0) 3.6e12)
                     :finds (into {} (for [p properties
                                           :when (= "failing" (:status p))
                                           :when (:independent_finds p)
                                           :when (or (:location p) (contains? system-crash-properties (:message p)))]
                                       [(:message p) (:independent_finds p)]))}]
        (when (contains? #{"stopped" "failed" "passed"} (:state run)) (swap! run-summaries assoc id summary))
        summary)))

(defn system-history
  "How each strategy did on this run's system and scenario in its last 30 finished runs: strategy ->
  {:runs :cpu_hours :finds_per_cpu_hour {property rate}}, from serve."
  [run-url]
  (let [[_ base id-text] (re-find #"^(.*)/runs/(\d+)$" run-url)
        id (parse-long id-text)
        runs (http-json (str base "/runs"))
        this (first (filter #(= id (:id %)) runs))
        this-compose (:compose (:request (http-json run-url)))
        same (->> runs
                  (filter #(and (not= id (:id %)) (= (system-key %) (system-key this))
                                (= (:scenario %) (:scenario this))
                                (contains? #{"stopped" "failed" "passed"} (:state %))))
                  (sort-by :id)
                  (take-last 30))
        ;; A run serve cannot summarize in time is left out, not the history.
        summaries (keep #(let [summary (try (run-summary base (:id %)) (catch Exception _ nil))]
                           (when (and summary (or (nil? this-compose) (= this-compose (:compose summary))))
                             summary))
                        same)]
    (into {} (for [[strategy group] (group-by :strategy summaries)
                   :let [cpu (reduce + (map :cpu_hours group))
                         finds (apply merge-with + {} (map :finds group))]]
               [strategy {:runs (clojure.core/count group)
                          :cpu_hours (/ (Math/round (* 10.0 cpu)) 10.0)
                          ;; Its own choices' skill: new failures per CPU-hour of the timelines it
                          ;; returned to (the fresh ones are no strategy's and fail alike).
                          :chosen_failing_anew_per_cpu_hour
                          (let [chosen (keep :chosen group)
                                hours (reduce + (map :cpu_hours chosen))]
                            (when (pos? hours)
                              (/ (Math/round (* 1000.0 (/ (reduce + (map :failing_anew chosen)) hours))) 1000.0)))
                          :finds_per_cpu_hour (into {} (for [[message n] finds]
                                                         [(clip message 100)
                                                          (/ (Math/round (* 1000.0 (/ n (max cpu 0.01)))) 1000.0)]))}]))))

(defn- run-state-for-advice [run-url]
  (let [properties (http-json (str run-url "/properties"))
        recent (take-last 8 @generations)]
    {:properties (vec (for [p properties :when (or (:location p) (contains? system-crash-properties (:message p)))]
                        {:message (clip (:message p) 160) :type (:type p) :status (:status p)
                         :finds (:independent_finds p) :timelines_failing (:timelines_failing p)}))
     :strategies (vec (sort (map name (keys @strategies))))
     :current (name @adaptive-choice)
     :recent_generations (vec (for [g recent]
                                {:generation (:generation g) :strategy (name (:strategy g))
                                 :chosen (vec (map #(clip (str (:reason %)) 160) (:chosen g)))}))
     :jev_calls (count @jev-calls)
     ;; Across runs: how each strategy did on this system before.
     :history (try (system-history run-url) (catch Exception e {:error (ex-message e)}))}))

(defn advise!
  "Asks Claude which strategy the run should use next; applies the answer. Returns it."
  [run-url]
  (let [state (run-state-for-advice run-url)
        prompt (str "You steer a deterministic simulation test (determinismo) that explores timelines of a "
                    "system under faults to find bugs. A tree explorer branches new timelines from moments of "
                    "earlier ones; a strategy chooses those moments. rarity: just after the rarest new behavior "
                    "(Go-Explore). jev / jev-blend / jev-blend-logs: a model's probability that branching there "
                    "finds a bug (blend: times rarity; logs: it also reads the timeline's last log lines). "
                    "archive: half from rarely revisited cells. uniform: random. Choose the strategy most likely "
                    "to find properties not failing yet, or to find failing ones in new ways. `history` says "
                    "how each strategy did on this system before (finds per CPU-hour per property): prefer "
                    "what found more, but try one with little history when the rest found nothing.\n"
                    "Run state:\n" (json/generate-string state) "\n"
                    "Answer with JSON only: {\"strategy\": \"<one of strategies>\", \"why\": \"<one sentence>\", "
                    "\"system\": \"<optional: what the system is and promises, for the model, or empty>\"}")
        result (try (let [process (.start (ProcessBuilder. ["claude" "-p" "--model" advisor-model prompt]))
                          out (slurp (.getInputStream process))]
                      (.waitFor process)
                      out)
                    (catch Exception e (str "error: " (ex-message e))))
        start (str/index-of result "{")
        end (str/last-index-of result "}")
        answer (when (and start end) (try (json/parse-string (subs result start (inc end)) true) (catch Exception _ nil)))
        choice (some-> (:strategy answer) keyword)
        applied (when (and choice (contains? @strategies choice) (not= choice :adaptive))
                  (reset! adaptive-choice choice)
                  (when-not (str/blank? (:system answer))
                    (swap! jev-systems assoc (:system_under_test (run-context run-url)) (:system answer)))
                  choice)]
    (swap! advice #(conj (if (>= (clojure.core/count %) 64) (subvec % 1) %)
                         {:run run-url :at (System/currentTimeMillis) :asked state :answer (or answer result)
                          :applied applied}))
    (binding [*out* *err*] (println "advice:" (pr-str (select-keys answer [:strategy :why])) "applied:" applied))
    answer))

;; Claude writes a strategy ------------------------------------------------------------------------
;; `(propose-strategy! run-url)` shows Claude the run (its properties and finds, the strategies'
;; history on its system, the last generations' candidates and choices) and this host's helpers,
;; and asks for one `(fn [generation candidates count] ...)`. The form is checked before anything
;; runs (only the helpers below, clojure.core's pure functions, str/ and Math/: no I/O, eval,
;; definitions, threads, Java calls or other namespaces), evaluated, and dry-run on the last
;; recorded generations (a time limit, the answer's shape checked); then registered as
;; `:claude-<n>` and its code kept in plugins/clojure/proposed/ for review. `:adaptive` may then
;; choose it like any other.

(def proposal-helpers
  "What a proposed strategy may call besides clojure.core's pure functions."
  '#{rarest-new new-behaviors room-end clamp-moment troubles logs-before jev-ask jev-context
     current-run ends seconds clip ms *archive* archive-returns failed-timeline?})

(def proposal-denied
  '#{eval load load-string load-file read-string slurp spit future future-call pmap pcalls
     agent send send-off def defn defmacro defonce intern ns require import use refer set!
     alter-var-root alter-meta! reset-meta! with-redefs binding locking monitor-enter
     monitor-exit new proxy reify deftype defrecord gen-class swap! reset! compare-and-set!
     shutdown-agents System Runtime Thread ProcessBuilder Class Object})

(defn- proposal-problems
  "Why a proposed form may not run: nil when it may."
  [form]
  (let [symbols (filter symbol? (tree-seq coll? seq form))
        bad (for [sym symbols
                  :let [ns-part (namespace sym) nm (name sym)]
                  :when (or (contains? proposal-denied sym)
                            (contains? proposal-denied (symbol nm)) ; clojure.core/eval too.
                            (str/starts-with? nm ".")
                            (and (str/ends-with? nm ".") (not= nm "."))
                            (and ns-part (not (contains? #{"str" "Math" "clojure.string" "clojure.core"} ns-part))))]
              sym)]
    (cond
      (not (and (seq? form) (= 'fn (first form)))) "not a (fn [generation candidates count] ...) form"
      (seq bad) (str "uses what a strategy may not: " (str/join " " (distinct bad))))))

(defonce proposals (atom []))  ; [{:name :code :problems :dry-run}]

(defn- dry-run [f]
  (let [samples (take-last 4 (filter #(seq (:candidates %)) @generations))]
    (if (empty? samples)
      {:ok false :why "no generation recorded to try it on"}
      (try
        (let [results (for [{:keys [generation candidates archive]} samples]
                        (let [answer (deref (future (binding [*archive* (or archive [])]
                                                      (f generation candidates 3)))
                                            30000 ::timeout)
                              _ (when (= ::timeout answer) (throw (ex-info "took over 30 s" {})))
                              _ (when (and (map? answer) (not (contains? #{nil "fresh" "explorer"} (:fill answer))))
                                  (throw (ex-info (str "a :fill other than fresh or explorer: " (pr-str (:fill answer))) {})))
                              result (vec (if (map? answer) (:returns answer) answer))]
                          (doseq [r result]
                            (when-not (and (int? (:branch r)) (int? (:vtime_ns r)) (string? (:reason r)))
                              (throw (ex-info (str "a return without :branch, :vtime_ns and :reason: " (pr-str r)) {}))))
                          (when (> (reduce + (map #(or (:branches %) 4) result)) 16)
                            (throw (ex-info "more branches than the generation's 16 timelines" {})))
                          result))]
          {:ok true :returns (mapv clojure.core/count (doall results))})
        (catch Throwable e {:ok false :why (ex-message e)})))))

(defn- proposal-name
  "The next proposal's name, past every one kept in proposed/ too: counted from this host's own
  proposals alone, a restarted host named one claude-2 again and overwrote the Jev A/B's."
  []
  (let [files (or (.listFiles (io/file (System/getProperty "user.dir") "proposed")) [])
        kept (keep #(some-> (re-matches #"claude-(\d+)\.clj" (.getName %)) second parse-long) files)]
    (keyword (str "claude-" (inc (apply max (clojure.core/count @proposals) 0 kept))))))

(defn propose-strategy!
  "Asks Claude for a strategy for the run, checks, dry-runs and registers it; its name, or the
  reason it was refused."
  [run-url]
  (let [state (run-state-for-advice run-url)
        sample (some->> @generations (filter #(seq (:candidates %))) last :candidates (take 3)
                        (mapv #(update % :behaviors (fn [bs] (vec (take 3 bs))))))
        prompt (str "Write a strategy for determinismo's tree explorer, which explores timelines of a "
                    "system under faults to find bugs and, after each generation, asks where to branch "
                    "new timelines from. Answer with ONE Clojure form and nothing else: "
                    "(fn [generation candidates count] ...) returning maps "
                    "{:branch <a candidate's :branch> :vtime_ns <a moment within its :start_ns..:end_ns> "
                    ":reason \"<why, one sentence, starting with claude:>\" :branches <optional: how many "
                    "timelines branch from it, 4 by default>}; the generation's 16 timelines are yours to "
                    "spend (`count` moments of 4 each is the explorer's own shape; 12 from one moment and "
                    "1 from another is fine), and returning {:returns [...] :fill \"fresh\"} starts the "
                    "timelines you leave fresh instead of the explorer's own picks (:fill \"explorer\", "
                    "the default). "
                    "A candidate: {:branch :start_ns :end_ns :novel :moment_ns :label :behaviors "
                    "[{:label :vtime_ns :new_in_generation :timelines_before}]}; sample: "
                    (json/generate-string sample) ". "
                    "You may use clojure.core's pure functions, str/ (clojure.string), Math/, and these "
                    "helpers: (rarest-new c) -> {:at :label :reached} or nil, the rarest behavior new to the "
                    "generation that leaves room; (new-behaviors c); (room-end c) its first four fifths' end; "
                    "(clamp-moment c at); (troubles @current-run [[branch from to] ...]) -> {branch {:at "
                    ":line}} each timeline's last ERROR/WARN/panic/fail log line in that span; "
                    "(logs-before @current-run [[branch at] ...]) -> {branch [lines]}; (jev-ask state "
                    "questions) -> a model's answers {:t<branch> {:noul p}} for questions {\"t<branch>\" "
                    "{:type \"noul\" :instructions \"...\"}}; (jev-context) the system's description; ms "
                    "(1e6); *archive* the explorer's Go-Explore archive cells offered this generation, most "
                    "promising first by its own rank, [{:branch :vtime_ns :label :timelines :returns :paid}] "
                    "(return to one by its :branch and :vtime_ns, though outside the candidates; the explorer "
                    "alone returns half to the frontier and half there, and its archive's returns find bugs "
                    "about as often as its frontier's); (archive-returns n) its first n as returns; "
                    "(failed-timeline? branch) whether that timeline failed a property: returning into one "
                    "finds nothing new (its children fail the same way: in an earlier A/B a strategy "
                    "returning after ERROR lines had 69 failing children, 11 failing anew). "
                    "No I/O, no definitions, no Java calls. Aim at what the run's state says: "
                    "properties not failing yet, rare bugs, what worked before (history).\n"
                    "Run state: " (json/generate-string state))
        answer (try (let [process (.start (ProcessBuilder. ["claude" "-p" "--model" advisor-model prompt]))
                          out (slurp (.getInputStream process))]
                      (.waitFor process)
                      out)
                    (catch Exception e (str "error: " (ex-message e))))
        start (str/index-of answer "(fn")
        form (when start (try (read-string (subs answer start)) (catch Exception _ nil)))
        problems (if form (proposal-problems form) "no (fn ...) form in the answer")
        f (when-not problems (try (eval form) (catch Throwable e nil)))
        result (cond problems {:ok false :why problems}
                     (not (fn? f)) {:ok false :why "it does not evaluate to a function"}
                     :else (dry-run f))
        name (proposal-name)]
    (swap! proposals conj {:name name :code (when form (pr-str form)) :problems problems :dry-run result})
    (if (:ok result)
      (let [file (io/file (str (System/getProperty "user.dir") "/proposed/" (clojure.core/name name) ".clj"))]
        (io/make-parents file)
        (spit file (str ";; Proposed by " advisor-model " for " run-url "; dry run: " (pr-str result) "\n"
                        (with-out-str (pprint/pprint form))))
        (swap! strategies assoc name {:returns f})
        (binding [*out* *err*] (println "proposal" name "registered:" (pr-str result)))
        name)
      (do (binding [*out* *err*] (println "proposal refused:" (:why result)))
          (:why result)))))

(defn stop-advising! [] (some-> @advising future-cancel) (reset! advising nil))

(defn advise-every!
  "advise! every `minutes` while the run is running (its state from serve)."
  [run-url minutes]
  (stop-advising!)
  (reset! advising
          (future
            (loop []
              (when (= "running" (:state (http-json run-url)))
                (try (advise! run-url) (catch Exception e (binding [*out* *err*] (println "advise:" (ex-message e)))))
                (Thread/sleep (* minutes 60000))
                (recur))))))

;; `:learn` learns which kinds of moments pay, during a run and across runs, with no model: a
;; moment's kind is its behavior's label with its numbers taken out ("[ERROR] node-# failed to
;; install snapshot"); each generation it returns just after the candidates' new behaviors whose
;; kinds paid best so far (UCB1: their share of branches that failed a property anew, plus a bonus
;; for kinds seldom tried), times their rarity, never into a timeline that failed; a branch's end
;; credits its moment's kind when it failed a property its parent never failed. Its record
;; (`learned`) outlives runs: the next run starts from what this one learned.

;; A branch pays a kind a whole point when it fails a property no timeline of the run failed
;; before (a bug not yet found), `learn-known-pay` when it only fails one anew against its parent
;; (a bug already found, again).
(defonce learned (atom {}))      ; Kind -> {:tries :paid}, across runs.
(defonce learn-chosen (atom {})) ; [branch vtime_ns] returned to -> its kind, this run.
(defonce run-failed (atom #{}))  ; The properties any timeline of this run failed so far.
(def learn-known-pay 0.25)
(def learn-bonus 0.5)

(defn moment-kind [label]
  (-> (str label)
      (str/replace #"0x[0-9a-fA-F]+" "#")
      (str/replace #"[0-9]+" "#")
      (str/replace #"#([.:/-]#)+" "#")
      (clip 90)))

(defn- learn-score
  "A kind's UCB1 score in a record (`learned`, :learn's, unless another is given)."
  [kind total & [record]]
  (let [{:keys [tries paid] :or {tries 0 paid 0}} (get @(or record learned) kind)]
    (+ (/ (+ paid 1.0) (+ tries 2.0))
       (* learn-bonus (Math/sqrt (/ (Math/log (+ total 2.0)) (+ tries 1.0)))))))

(defn learn-returns [generation candidates count]
  (let [total (reduce + (map :tries (vals @learned)))
        scored (for [c candidates
                     :when (not (failed-timeline? (:branch c)))
                     b (new-behaviors c)
                     :when (<= (:vtime_ns b) (room-end c))
                     :let [kind (moment-kind (:label b))]]
                 {:branch (:branch c) :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000)) :kind kind
                  :score (/ (learn-score kind total) (max 1 (:new_in_generation b)))})
        chosen (->> scored
                    (sort-by (juxt (comp - :score) :branch))
                    (reduce (fn [taken r] (if (some #(= (:branch %) (:branch r)) taken) taken (conj taken r))) [])
                    (take count))]
    (doseq [{:keys [branch vtime_ns kind]} chosen]
      (swap! learn-chosen assoc [branch vtime_ns] kind))
    (for [{:keys [branch vtime_ns kind score]} chosen
          :let [{:keys [tries paid] :or {tries 0 paid 0}} (get @learned kind)]]
      {:branch branch :vtime_ns vtime_ns
       :reason (format "learn: after %s, its kind paid %.2f of %d branches so far (score %.2f)"
                       kind (double paid) tries (double score))})))

(defn learn-end
  "Credits the kind of the moment a timeline was returned to (in `learned`, :learn's record,
  unless another is given), and notes the run's failed properties."
  [_state {:keys [index failing]} & [record]]
  (let [known @run-failed]
    (swap! run-failed into failing)
    (when-let [{:keys [branch vtime_ns]} (:from (get @starts index))]
      (when-let [kind (get @learn-chosen [branch vtime_ns])]
        (let [parent (set (:failing (get @ends branch)))
              first-in-run (some #(not (known %)) failing)
              anew (some #(not (parent %)) failing)
              pay (cond first-in-run 1.0 anew learn-known-pay :else 0.0)]
          (swap! (or record learned) update kind (fn [{:keys [tries paid] :or {tries 0 paid 0}}]
                                                  {:tries (inc tries) :paid (+ paid pay)})))))))

;; `:mix` is a portfolio that learns: each generation's returns split among its members (the
;; explorer's whole rule, :learn, :jev-archive, Claude's evolving strategy), a slot each to the
;; members whose picks paid best so far (UCB1, credited as :learn credits a kind: a whole point for
;; a branch failing a property no timeline of the run failed before, a quarter for one only anew
;; against its parent), the record kept across runs: the mix moves to what finds new bugs here.

(def mix-members [:rarity :learn :jev-archive :evolve])
(defonce mix-record (atom {}))  ; Member -> {:tries :paid}, across runs.
(defonce mix-chosen (atom {}))  ; [branch vtime_ns] returned to -> its member, this run.
(def mix-bonus 0.5)

(defn- mix-score [member total]
  (let [{:keys [tries paid] :or {tries 0 paid 0}} (get @mix-record member)]
    (+ (/ (+ paid 1.0) (+ tries 2.0))
       (* mix-bonus (Math/sqrt (/ (Math/log (+ total 2.0)) (+ tries 1.0)))))))

(defn mix-returns [generation candidates count]
  (let [total (reduce + (map :tries (vals @mix-record)))
        ranked (sort-by (juxt #(- (mix-score % total)) name) mix-members)
        picks (into {} (for [member ranked
                             :let [f (:returns (get @strategies member))]
                             :when f]
                         [member (try (vec (let [answer (f generation candidates count)]
                                             (if (map? answer) (:returns answer) answer)))
                                      (catch Exception e
                                        (binding [*out* *err*] (println "mix:" member (ex-message e)))
                                        []))]))
        ;; Round by round, each member in rank its next pick not taken yet, until `count`.
        chosen (loop [chosen [] round 0]
                 (if (or (>= (clojure.core/count chosen) count) (> round count))
                   (vec (take count chosen))
                   (recur (reduce (fn [taken member]
                                    (if (>= (clojure.core/count taken) count)
                                      taken
                                      (if-let [pick (->> (get picks member)
                                                         (remove (fn [r] (some #(and (= (:branch %) (:branch r))
                                                                                     (= (:vtime_ns %) (:vtime_ns r)))
                                                                               taken)))
                                                         first)]
                                        (conj taken (assoc pick :member member))
                                        taken)))
                                  chosen ranked)
                          (inc round))))]
    (doseq [{:keys [branch vtime_ns member]} chosen]
      (swap! mix-chosen assoc [branch vtime_ns] member))
    (for [{:keys [member reason] :as pick} chosen]
      (-> pick (dissoc :member :score :kind)
          (assoc :reason (str "mix[" (name member) "]: " reason))))))

(defn mix-end [state {:keys [index failing] :as request}]
  (let [known @run-failed]
    (learn-end state request) ; :learn's own credit (and the run's failed properties).
    (when-let [{:keys [branch vtime_ns]} (:from (get @starts index))]
      (when-let [member (get @mix-chosen [branch vtime_ns])]
        (let [parent (set (:failing (get @ends branch)))
              pay (cond (some #(not (known %)) failing) 1.0
                        (some #(not (parent %)) failing) learn-known-pay
                        :else 0.0)]
          (swap! mix-record update member (fn [{:keys [tries paid] :or {tries 0 paid 0}}]
                                            {:tries (inc tries) :paid (+ paid pay)})))))))

;; `:council`: every decision made by all of them together. Each generation the explorer proposes
;; (its frontier, the rarest new behavior of each timeline that did not fail, and its archive's
;; best cells), and every candidate is judged at once by its rarity (the explorer's), its kind's
;; record of failing properties not yet found (as :learn's, its own), and Jev's probability of a failure not
;; yet had (one call): a weighted product, under the weights and the boosts of kinds of moment
;; Claude sets reviewing how the council's picks paid (every `council-review-minutes`). Inside
;; each timeline Jev plans its named decisions beside it (:jev-follow's). A branch credits its
;; moment's kind as :learn does, so what pays feeds the next choices, across runs too.

(def council-review-minutes 5)
(defonce council-weights (atom {:rarity 1.0 :jev 1.0 :learn 1.0}))
(defonce council-learned (atom {})) ; Its own record of kinds of moment (as :learn's), across runs.
(defonce council-boosts (atom {}))    ; A piece of a kind -> its factor (Claude's).
(defonce council-reviews (atom []))   ; [{:run :at :answer :applied}]
(defonce council-reviewing (atom nil))
(defonce council-decisions (atom [])) ; The last 64 chosen, with their parts.

(defn- council-boost [kind]
  (reduce * 1.0 (for [[piece factor] @council-boosts :when (str/includes? kind piece)] factor)))

(defn- interleave-all
  "The first of each, then the second of each, ..., the longer ones going on alone."
  [& colls]
  (lazy-seq (let [ss (keep seq colls)]
              (when (seq ss) (concat (map first ss) (apply interleave-all (map rest ss)))))))

(defn- faults-before [branch vtime_ns]
  (vec (take-last 4 (for [entry (get @jev-stories branch) :when (and (:fault entry) (< (:at_ns entry) vtime_ns))]
                      (str (:fault entry) " at " (seconds (:at_ns entry)) " s")))))

(defn- council-shortlist
  "The candidates, in turns from each who proposes: the explorer's frontier (the rarest new
  behavior of each timeline that did not fail), its archive's best cells, and each timeline's own
  story (just after a fault it was given, the rarer kinds in the generation first)."
  [candidates count]
  (let [frontier (for [c candidates
                       :when (not (failed-timeline? (:branch c)))
                       :let [roomy (filter #(<= (:vtime_ns %) (room-end c)) (new-behaviors c))]
                       :when (seq roomy)
                       :let [b (apply min-key :new_in_generation roomy)]]
                   {:branch (:branch c) :vtime_ns (clamp-moment c (+ (:vtime_ns b) 1000)) :label (:label b)
                    :rarity (/ 1.0 (max 1 (:new_in_generation b))) :from "frontier"})
        archived (for [cell (take (* 2 count) *archive*)
                       :when (not (failed-timeline? (:branch cell)))]
                   {:branch (:branch cell) :vtime_ns (:vtime_ns cell) :label (:label cell)
                    :rarity (/ (inc (:paid cell)) (* (inc (:timelines cell)) (inc (:returns cell)) 1.0))
                    :from "archive"})
        given (for [c candidates
                    :when (not (failed-timeline? (:branch c)))
                    :let [end (room-end c)]
                    entry (take-last 3 (filter #(and (:fault %) (> (:at_ns %) (:start_ns c)) (<= (:at_ns %) end))
                                               (get @jev-stories (:branch c))))]
                {:branch (:branch c) :vtime_ns (clamp-moment c (+ (:at_ns entry) 1000))
                 :label (str "the fault " (:fault entry)) :from "story"})
        kinds (frequencies (map (comp moment-kind :label) given))
        story (for [m given] (assoc m :rarity (/ 1.0 (get kinds (moment-kind (:label m))))))]
    (vec (take jev-questions-max
               (interleave-all (take (* 2 count) (sort-by (comp - :rarity) frontier))
                               archived
                               (take (* 2 count) (sort-by (comp - :rarity) story)))))))

(defn council-returns [generation candidates count]
  (let [shortlist (council-shortlist candidates count)
        total (reduce + (map :tries (vals @council-learned)))
        answers (if (seq shortlist)
                  (jev-ask (assoc (jev-described)
                                  :how (str "A deterministic simulation explores timelines of the system under "
                                            "faults; from a moment of a timeline, new timelines continue with "
                                            "other decisions.")
                                  :generation generation
                                  :moments (for [[i m] (map-indexed vector shortlist)]
                                             {:moment i :timeline (:branch m) :at_s (seconds (:vtime_ns m))
                                              :just_after (clip (:label m) 120)
                                              :faults_before (faults-before (:branch m) (:vtime_ns m))
                                              :already_failed (vec (take 6 (:failing (get @ends (:branch m)))))}))
                           (into {} (for [[i m] (map-indexed vector shortlist)]
                                      [(str "m" i)
                                       {:type "noul"
                                        :instructions (str "Branching again from timeline " (:branch m) " just after '"
                                                           (clip (:label m) 100) "' is likely to make one of the "
                                                           "system's properties fail" jev-anew)}])))
                  {})
        {wr :rarity wj :jev wl :learn} @council-weights
        judged (for [[i m] (map-indexed vector shortlist)
                     :let [kind (moment-kind (:label m))
                           p (or (get-in answers [(keyword (str "m" i)) :noul]) 0.25)
                           l (learn-score kind total council-learned)
                           boost (council-boost kind)
                           score (* boost (Math/exp (+ (* wr (Math/log (max (:rarity m) 1e-3)))
                                                       (* wj (Math/log (max (double p) 1e-3)))
                                                       (* wl (Math/log l)))))]]
                 (assoc m :kind kind :jev (double p) :learn l :boost boost :score score))
        chosen (->> judged
                    (sort-by (comp - :score))
                    (reduce (fn [taken r] (if (some #(and (= (:branch %) (:branch r)) (= (:vtime_ns %) (:vtime_ns r))) taken)
                                            taken (conj taken r))) [])
                    (take count))]
    (doseq [{:keys [branch vtime_ns kind]} chosen]
      (swap! learn-chosen assoc [branch vtime_ns] kind))
    (swap! council-decisions #(vec (take-last 64 (concat % (map (fn [d] (dissoc d :vtime_ns)) chosen)))))
    (for [{:keys [branch vtime_ns from label rarity jev learn boost score]} chosen]
      {:branch branch :vtime_ns vtime_ns
       :reason (format "council: %s, just after %s: rarity %.2f, Jev %.2f, learn %.2f, Claude x%.1f -> %.3f"
                       from (clip label 70) (double rarity) jev (double learn) (double boost) (double score))})))

(defonce fault-learned (atom {})) ; A kind of fault chosen -> {:tries :paid}, across runs.

(defn- fault-score [kind total]
  (let [{:keys [tries paid] :or {tries 0 paid 0}} (get @fault-learned kind)]
    (+ (/ (+ paid 1.0) (+ tries 2.0))
       (* learn-bonus (Math/sqrt (/ (Math/log (+ total 2.0)) (+ tries 1.0)))))))

(defn council-weights-adjust
  "Jev's weights for a decision's options times each option's learned payoff (its kind's record
  of timelines failing a property not yet found) and Claude's boosts."
  [label options weights]
  (let [total (reduce + (map :tries (vals @fault-learned)))
        {wj :jev wl :learn} @council-weights]
    (into {} (for [[i p] weights
                   :let [kind (decision-kind label (nth options i))]]
               [i (* (Math/pow (max (double p) 1e-3) wj)
                     (Math/pow (fault-score kind total) wl)
                     (council-boost kind))]))))

(defn council-decide
  "A timeline's named decision with all of them: Jev's plan for it, each option's learned payoff
  (its kind's record of timelines failing a property not yet found) and Claude's boosts."
  [state request]
  (jev-follow-decide
   state request
   :prefix "council"
   :adjust (fn [label options weights]
             (let [total (reduce + (map :tries (vals @fault-learned)))
                   {wj :jev wl :learn} @council-weights]
               (into {} (for [[i p] weights
                              :let [kind (decision-kind label (nth options i))]]
                          [i (* (Math/pow (max (double p) 1e-3) wj)
                                (Math/pow (fault-score kind total) wl)
                                (council-boost kind))]))))))

(defn council-end
  "A timeline's end credits the kinds of fault it chose itself (after its moment) as :learn credits
  a moment's kind, then jev-follow's and :learn's own ends."
  [state {:keys [index failing] :as request}]
  (let [known @run-failed
        from (:from (get @starts index))
        parent (if from (set (:failing (get @ends (:branch from)))) #{})
        pay (cond (some #(not (known %)) failing) 1.0
                  (some #(not (parent %)) failing) learn-known-pay
                  :else 0.0)
        start (or (:vtime_ns from) 0)
        own (distinct (for [entry (:story @state) :when (and (:chose entry) (> (:at_ns entry) start))]
                        (moment-kind (:chose entry))))]
    (doseq [kind own]
      (swap! fault-learned update kind (fn [{:keys [tries paid] :or {tries 0 paid 0}}]
                                         {:tries (inc tries) :paid (+ paid pay)})))
    (jev-follow-end state request)
    (learn-end state request council-learned)))

;; `:council-ender`: the council, and it ends a timeline headed only for failures the run already
;; has (an event's reply `{"end": true}`), so its worker starts another: the timeline failed only
;; properties some timeline of the run failed before, the first of them `ender-quiet-ns` ago, and
;; reached no new code for `ender-quiet-ns`. Its end's checks are not run: an arm to measure.
(def ender-quiet-ns (* 10 1000000000))
(defonce ender-stats (atom {})) ; run_url -> {:ended n}

(defn council-ender-event [state {:keys [vtime_ns event] :as request}]
  (jev-follow-event state request)
  (let [assertion (or (:assert event) (:antithesis_assert event))]
    (when (and assertion (false? (:condition assertion)) (not (false? (:hit assertion)))
               (#{"always" "always_or_unreachable"} (or (:type assertion) (:assert_type assertion))))
      (swap! state (fn [now] (-> now
                                 (update :failed_names (fnil conj #{}) (str (:message assertion)))
                                 (update :failed_at #(or % vtime_ns))))))
    (let [{:keys [failed_names failed_at story]} @state
          last-new (reduce max 0 (keep #(when (:reached %) (:at_ns %)) story))
          known @run-failed]
      (when (and (seq failed_names) (every? known failed_names)
                 (>= (- vtime_ns failed_at) ender-quiet-ns)
                 (>= (- vtime_ns last-new) ender-quiet-ns))
        (swap! ender-stats update (str @current-run) #(update (or % {}) :ended (fnil inc 0)))
        end-timeline))))

(defn- council-apply! [answer]
  (let [start (str/index-of answer "{")
        parsed (when start (try (json/parse-string (subs answer start (inc (str/last-index-of answer "}"))) true)
                                (catch Exception _ nil)))
        clamp (fn [x lo hi] (when (number? x) (max lo (min hi (double x)))))
        weights (into {} (for [k [:rarity :jev :learn] :let [v (clamp (get-in parsed [:weights k]) 0.0 3.0)] :when v] [k v]))
        boosts (into {} (for [[k v] (:boost parsed) :let [f (clamp v 0.2 5.0)] :when (and f (seq (name k)))]
                          [(clip (name k) 90) f]))]
    (when (seq weights) (swap! council-weights merge weights))
    (when (map? (:boost parsed)) (reset! council-boosts (into {} (take 12 boosts))))
    (boolean (or (seq weights) (seq boosts)))))

(defn council-review!
  "Claude reviews how the council's picks paid and sets its weights and boosts."
  [run-url]
  (let [kinds (->> @council-learned (sort-by (comp - :tries val)) (take 30)
                   (map (fn [[kind {:keys [tries paid]}]] {:kind kind :branches tries :paid paid})))
        faults (->> @fault-learned (sort-by (comp - :tries val)) (take 20)
                    (map (fn [[kind {:keys [tries paid]}]] {:fault kind :timelines tries :paid paid})))
        state {:weights @council-weights :boosts @council-boosts :kinds kinds :fault_kinds faults
               :recent_decisions (vec (for [d (take-last 12 @council-decisions)]
                                        (select-keys d [:from :label :rarity :jev :learn :boost :score])))
               :properties (try (vec (for [p (http-json (str run-url "/properties"))
                                           :when (or (:location p) (contains? system-crash-properties (:message p)))]
                                       {:message (clip (:message p) 120) :status (:status p)}))
                                (catch Exception _ []))}
        prompt (str "You tune how determinismo's strategy council chooses where a deterministic simulation "
                    "branches new timelines to find bugs. Each candidate moment is scored rarity^w_rarity x "
                    "jev^w_jev x learn^w_learn x boost: rarity is how few timelines reached the behavior, jev a "
                    "model's probability of a new failure there, learn how often branches from moments of that "
                    "kind failed a property not yet failed (paid / branches). Inside each timeline its faults are "
                    "drawn the same way: jev^w_jev x learn^w_learn x boost over the fault kinds (fault_kinds: "
                    "timelines that chose one, and how they paid; they include when faults come, as thirds of "
                    "the injector's timing draws: 'fault.quiet_ms long (over # s)' is a long quiet pause between "
                    "bursts), so a boost may name a fault or a timing too. Bugs not yet "
                    "found (properties not failing yet) matter most. Answer only JSON: {\"weights\": {\"rarity\": 0..3, \"jev\": 0..3, "
                    "\"learn\": 0..3}, \"boost\": {\"<a piece of a kind's text>\": 0.2..5, ...}} (up to 12 boosts, "
                    "they replace the current ones), from the evidence below; keep a weight where the evidence is "
                    "thin.\nState: " (json/generate-string state))
        answer (try (let [process (.start (ProcessBuilder. ["claude" "-p" "--model" advisor-model prompt]))
                          out (slurp (.getInputStream process))]
                      (.waitFor process)
                      out)
                    (catch Exception e (str "error: " (ex-message e))))
        applied (council-apply! answer)]
    (swap! council-reviews #(vec (take-last 200 (conj % {:run run-url :at (str (java.time.Instant/now)) :answer (clip answer 400)
                                                           :applied applied :weights @council-weights :boosts @council-boosts}))))
    applied))

(defn stop-council-review! [] (some-> @council-reviewing future-cancel) (reset! council-reviewing nil))

(defonce council-reviewing-run (atom nil))

(defn council-review-every!
  "Claude's review loop for the run, once (every worker's hello calls this; a restart at each
  would keep the first review from coming)."
  [run-url minutes]
  (when-not (and (= run-url @council-reviewing-run) @council-reviewing (not (future-done? @council-reviewing)))
    (stop-council-review!)
    (reset! council-reviewing-run run-url)
    (reset! council-reviewing
            (future
              (loop []
                (Thread/sleep (* minutes 60000))
                (when (= "running" (:state (http-json run-url)))
                  (try (council-review! run-url) (catch Exception e (binding [*out* *err*] (println "council:" (ex-message e)))))
                  (recur)))))))

;; `:evolve` rewrites itself: its returns are Claude's latest proposal's (propose-strategy!: written,
;; checked, dry-run on the run's own generations), the explorer's rule until there is one. While a
;; run of it goes on, every `evolve-minutes` Claude proposes again from the run's state and the
;; system's history (each strategy's finds, and its chosen timelines' new failures per CPU-hour);
;; a proposal that passes takes over from the next generation, and the next run starts from the
;; last one (`evolved` outlives runs).

(def evolve-minutes 7)
(defonce evolved (atom nil))  ; The proposal :evolve follows now (a strategy's name), across runs.
(defonce evolutions (atom [])) ; [{:run :at :proposal :taken}]
(defonce evolving (atom nil))  ; The loop's future.

(defn evolve-returns [generation candidates count]
  (let [f (or (some->> @evolved (get @strategies) :returns) rarity)]
    (f generation candidates count)))

(defn stop-evolving! [] (some-> @evolving future-cancel) (reset! evolving nil))

(defn evolve!
  "One step: a new proposal from the run; followed if it passed."
  [run-url]
  (let [proposal (propose-strategy! run-url)
        taken (keyword? proposal)]
    (when taken (reset! evolved proposal))
    (swap! evolutions conj {:run run-url :at (str (java.time.Instant/now)) :proposal proposal :taken taken})
    proposal))

(defonce evolving-run (atom nil))

(defn evolve-every!
  "Claude's loop for the run, once: every exploration worker's hello calls this, and restarting
  the loop at each kept its first 7 minutes from ever ending (run 1385)."
  [run-url minutes]
  (when-not (and (= run-url @evolving-run) @evolving (not (future-done? @evolving)))
    (stop-evolving!)
    (reset! evolving-run run-url)
    (reset! evolving
            (future
              (loop []
                (Thread/sleep (* minutes 60000))
                (when (= "running" (:state (http-json run-url)))
                  (try (evolve! run-url) (catch Exception e (binding [*out* *err*] (println "evolve:" (ex-message e)))))
                  (recur)))))))

;; Causality planners -----------------------------------------------------------------------------
;; A plan request: {:round :branch :property :snapshot_ms :failure_ms :futures :points_asked
;; :jump_min :gap_min_ms :moments_left :run_url :tape :points [{:vtime_ms :futures :failing
;; :probability :low :high}]}. A plan: {:moments [{:vtime_ms :futures}] :note "why"}; none: done.

(defonce plans (atom [])) ; [{:planner :request :plan}]

(defn- evenly
  "Just after the setup snapshot (the bug's probability before the timeline did anything), then
  `count` moments evenly to the failure (the last one at it)."
  [{:keys [snapshot_ms failure_ms futures]} count]
  (cons {:vtime_ms (inc snapshot_ms) :futures futures}
        (for [index (range 1 (inc count))]
          {:vtime_ms (+ snapshot_ms (max 1 (quot (* (- failure_ms snapshot_ms) index) count)))
           :futures futures})))

(defn jumps
  "Neighboring points whose probabilities differ by jump_min or more and are gap_min_ms apart or
  more, the largest first: [[a b] ...]."
  [{:keys [points jump_min gap_min_ms]}]
  (->> (sort-by :vtime_ms points)
       (partition 2 1)
       (filter (fn [[a b]] (and (>= (- (:vtime_ms b) (:vtime_ms a)) gap_min_ms)
                                (>= (abs (- (:probability b) (:probability a))) jump_min))))
       (sort-by (fn [[a b]] (- (abs (- (:probability b) (:probability a))))))))

(defn plan-bisect
  "causality.zig's own: k moments evenly, then halfway inside the largest jumps."
  [{:keys [round points_asked futures] :as request}]
  (if (zero? round)
    {:moments (evenly request points_asked) :note "evenly"}
    {:moments (for [[a b] (take points_asked (jumps request))]
                {:vtime_ms (+ (:vtime_ms a) (quot (- (:vtime_ms b) (:vtime_ms a)) 2)) :futures futures})
     :note "halfway inside the jumps"}))

(defn plan-faults
  "Evenly first; then, inside each jump, a moment just before and just after every fault
  injected there (the timeline's, from the run's API): the probability on either side of a fault
  says whether that fault decided the bug. A jump with no fault in it is halved."
  [{:keys [round points_asked futures run_url branch failure_ms] :as request}]
  (if (or (zero? round) (nil? run_url))
    (plan-bisect request)
    (let [faults (api/faults run_url branch failure_ms nil)
          known (set (map :vtime_ms (:points request)))
          inside (fn [[a b]] (filter #(< (:vtime_ms a) (:vtime_ms %) (:vtime_ms b)) faults))
          around (fn [[a b] fault]
                   (for [t [(dec (:vtime_ms fault)) (inc (:vtime_ms fault))]
                         :when (and (< (:vtime_ms a) t) (<= t (:vtime_ms b)) (not (known t)))]
                     {:vtime_ms t :futures futures}))
          moments (for [jump (take points_asked (jumps request))
                        moment (let [in (inside jump)]
                                 (if (seq in)
                                   (mapcat #(around jump %) in)
                                   [{:vtime_ms (+ (:vtime_ms (first jump))
                                                  (quot (- (:vtime_ms (second jump)) (:vtime_ms (first jump))) 2))
                                     :futures futures}]))]
                    moment)]
      {:moments (distinct moments)
       :note (str "around the faults inside " (count (jumps request)) " jumps: "
                  (str/join ", " (for [jump (jumps request) fault (inside jump)]
                                   (str (:kind fault) " " (:node fault) " at " (:vtime_ms fault) "ms"))))})))

(defn plan-dense
  "Four times the moments, evenly, in one round: no refinement."
  [{:keys [round points_asked] :as request}]
  (if (zero? round)
    {:moments (evenly request (* 4 points_asked)) :note "dense"}
    {:moments []}))

(defonce planners
  (atom {:bisect {:plan #'plan-bisect}
         :faults {:plan #'plan-faults}
         :dense {:plan #'plan-dense}}))

(defonce current-planner (atom :faults))

(defn use-planner! [name]
  (assert (contains? @planners name) (str "no planner " name))
  (reset! current-planner name))

(defn plan-answer [{:keys [method] :as request} _state]
  (case method
    "hello" {:name (str "clojure/" (name @current-planner))}
    "plan" (let [planner @current-planner
                 plan (try ((:plan (get @planners planner)) request)
                           (catch Exception e
                             (binding [*out* *err*] (println "planner" planner "failed:" (ex-message e)))
                             {:moments [] :note (str "failed: " (ex-message e))}))
                 plan (update plan :moments vec)]
             (swap! plans conj {:planner planner :request request :plan plan})
             plan)
    {}))

;; The protocol -----------------------------------------------------------------------------------

(declare answer*)

(defn answer
  "A request's reply; one that fails is said (its method, the error, the stack) and answered {}:
  the explorer goes on with its own choices. Here, not in the connection's loop, so listeners
  started before a reload get it too (they call this var; a failure in an old loop closed the
  connection and failed the explorer's worker: PluginExited)."
  [request state]
  (try (answer* request state)
       (catch Throwable e
         (binding [*out* *err*]
           (println "answer failed:" (:method request) "-" (str e))
           (.printStackTrace e))
         {})))

(defn- answer* [{:keys [method] :as request} state]
  (case method
    "hello" (let [strategy (get @strategies (strategy-name))]
              (run-started! request)
              {:name (str "clojure/" (name (strategy-name))) :decides (boolean (:decide strategy))
               :wants (or (:wants strategy) ["behaviors"])})
    "branch" (do (swap! starts assoc (:index request) (select-keys request [:seed :from]))
                 (reset! state {}) ; A timeline of its own.
                 (when-let [f (:branch (get @strategies (strategy-name)))] (f state request))
                 {})
    ;; An :event fn returning `end-timeline` ends the timeline at this moment.
    "event" (let [f (:event (get @strategies (strategy-name)))
                  result (when f (f state request))]
              (if (identical? result end-timeline) {:end true} {}))
    ;; A batch of them ("wants": ["batched"]: one round trip for many), each as an event request.
    "events" (let [{f :event plan :plan} (get @strategies (strategy-name))
                   ended (when f (reduce (fn [ended e]
                                           (let [result (f state (assoc e :method "event"))]
                                             (or ended (identical? result end-timeline))))
                                         false (:events request)))
                   planned (when plan (plan state))]
               (cond-> (if ended {:end true} {})
                 (seq planned) (assoc :plan planned)))
    "random" (or (when-let [f (:decide (get @strategies (strategy-name)))]
                   (try (f state request)
                        (catch Exception e
                          (binding [*out* *err*] (println "decide failed:" (ex-message e)))
                          nil)))
                 {})
    "branch_end" (do (swap! ends assoc (:index request) (select-keys request [:outcome :events :failing]))
                     (when-let [f (:end (get @strategies (strategy-name)))] (f state request))
                     {})
    "returns" (let [{:keys [generation candidates count archive]} request
                    strategy (strategy-name)
                    ;; A strategy answers its returns, or {:returns [...] :fill "fresh"|"explorer"}:
                    ;; each return may say its :branches (the generation's shape is its own:
                    ;; the request's :budget timelines in all, :branches each by default).
                    answer (try (binding [*archive* (or archive [])]
                                  ((:returns (get @strategies strategy)) generation candidates count))
                                (catch Exception e
                                  (binding [*out* *err*] (println "strategy" strategy "failed:" (ex-message e)))
                                  []))
                    fill (when (map? answer) (:fill answer))
                    chosen (vec (if (map? answer) (:returns answer) answer))]
                (swap! generations #(conj (if (>= (clojure.core/count %) 64) (subvec % 1) %) ; The last 64 (`count` is the request's here).
                                          {:generation generation :strategy strategy
                                         :candidates candidates :archive archive :chosen chosen}))
                (cond-> (if (seq chosen)
                          {:returns (mapv #(select-keys % [:branch :vtime_ns :reason :horizon_ns :branches]) chosen)}
                          {})
                  fill (assoc :fill fill)))
    {}))

(declare listen serve-with)

(defn serve-strategy!
  "A port whose connections always use the strategy `name`: `(serve-strategy! :jev 9111)`."
  [name port]
  (assert (contains? @strategies name) (str "no strategy " name))
  (listen port (serve-with (fn [request state] (binding [*pinned* name] (answer request state))))))

(defn- serve-with [answer-fn]
  (fn [socket]
    (future
      (let [state (atom {})] ; The connection's: one exploration worker's timelines.
        (with-open [socket socket
                    reader (io/reader (.getInputStream socket))
                    writer (io/writer (.getOutputStream socket))]
          (doseq [line (line-seq reader)]
            ;; A request that fails is said (its method, the error) and answered {}: the explorer
            ;; goes on with its own choices; an exception here once closed the connection unsaid,
            ;; and the explorer's worker failed (PluginExited).
            (let [reply (try (answer-fn (json/parse-string line true) state)
                             (catch Throwable e
                               (binding [*out* *err*]
                                 (println "answer failed:" (subs line 0 (min 80 (count line))) "-" (str e))
                                 (.printStackTrace e))
                               {}))]
              (.write writer (str (json/generate-string reply) "\n"))
              (.flush writer))))))))

(defn- serve-control [socket]
  (future
    (with-open [socket socket
                reader (io/reader (.getInputStream socket))
                writer (io/writer (.getOutputStream socket))]
      (doseq [line (line-seq reader)]
        (let [[command argument] (str/split (str/trim line) #"\s+" 2)
              reply (case command
                      "use" (try (use-strategy! (keyword argument)) "ok"
                                 (catch Throwable e (str "error " (ex-message e))))
                      "planner" (try (use-planner! (keyword argument)) "ok"
                                     (catch Throwable e (str "error " (ex-message e))))
                      "reset" (do (reset! generations []) (reset! ends {}) (reset! starts {})
                                  (reset! archive {}) (reset! jev-weights {}) (reset! jev-options {})
                                  (reset! jev-properties {}) (reset! jev-history []) "ok")
                      "events-dir" (do (reset! events-dir argument) "ok")
                      "jev-system" (do (reset! jev-system argument) "ok")
                      ;; What the strategies did, by run (its run_url): how much jev-follow steered,
                      ;; :evolve's proposals. One JSON line (ab.py --host-control).
                      "stats" (json/generate-string
                               {:jev_follow (assoc @jev-follow-by-run (str @current-run) @jev-follow-stats)
                                :evolutions @evolutions
                                :council_reviews (for [r @council-reviews] (dissoc r :answer))
                                :ended_early @ender-stats
                                ;; What the learning strategies learned, across runs: the kinds tried
                                ;; most, each with its pay (a point per new property failed).
                                :learned (into {} (for [[k record] {:learn @learned :council @council-learned
                                                                    :faults @fault-learned}]
                                                    [k (vec (for [[kind {:keys [tries paid]}]
                                                                  (take 12 (sort-by (comp - :tries val) record))]
                                                              {:kind kind :tries tries :paid paid}))]))})
                      "jev-system-for" (let [[piece text] (str/split (or argument "") #"\s+" 2)]
                                         (swap! jev-systems assoc piece text)
                                         "ok")
                      (str "error unknown command " command))]
          (.write writer (str reply "\n"))
          (.flush writer))))))

(defn- listen [port serve]
  (let [server (ServerSocket. port 50 (java.net.InetAddress/getByName "127.0.0.1"))]
    (future (loop [] (serve (.accept server)) (recur)))
    server))

(defn -main [& args]
  (let [options (apply hash-map args)
        port (parse-long (get options "--port" "9100"))
        control (parse-long (get options "--control" "9101"))
        planner-port (parse-long (get options "--planner-port" "9102"))
        repl (parse-long (get options "--nrepl" "1667"))]
    (when-let [strategy (get options "--strategy")] (use-strategy! (keyword strategy)))
    (when-let [planner (get options "--planner")] (use-planner! (keyword planner)))
    (reset! events-dir (get options "--events-dir"))
    (when-let [file (get options "--jev-key-file")] (reset! jev-key (str/trim (slurp file))))
    (when-let [system (get options "--jev-system")] (reset! jev-system system))
    (listen port (serve-with #'answer))
    (doseq [pair (str/split (get options "--strategy-ports" "") #",")
            :when (not (str/blank? pair))
            :let [[strategy strategy-port] (str/split pair #":")]]
      (serve-strategy! (keyword strategy) (parse-long strategy-port)))
    (listen planner-port (serve-with #'plan-answer))
    ;; Through the var: a reloaded serve-control answers at once (the function itself, the listener
    ;; kept the one it started with, and a host started before "stats" never knew it).
    (listen control #'serve-control)
    (nrepl/start-server :bind "127.0.0.1" :port repl)
    (println (str "strategies: protocol on 127.0.0.1:" port ", causality planners on " planner-port
                  ", control on " control ", nREPL on " repl "; strategy " (name @current)
                  ", planner " (name @current-planner)))
    @(promise)))
