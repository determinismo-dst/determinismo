;; SPDX-License-Identifier: MIT
;; The moment lab: a session's moment as a world to look at and act in, from Clojure, babashka or
;; jank (clients/jank-viz draws it and acts from its buttons). The world at the moment is
;; derived from the timeline's own events (the faults on, each node's starts and ends, failed
;; assertions, the test commands' outcomes) and the nodes' processes as `det-nodes list` reads
;; them. Every action is a step of the session, so it is on the session's timeline: recorded,
;; queried and replayed as any timeline is.
;;
;;   (require '[determinismo.lab :as lab])
;;   (def s (lab/open! 2163 {:branch 0 :at-vtime-ms 30000}))   ; a session, the lab on it
;;   (lab/world)                                                ; nodes, links, faults, badges
;;   (lab/fault! s {:kind "partition_groups" :groups [["rq-1"] ["rq-2" "rq-3"]]
;;                  :direction "outbound" :duration_ms 3000})  ; det-faults inject, a step
;;   (lab/advance! s 1000)                                      ; det:wait: 1 s of the timeline
;;   (lab/until! s "event=node_start details.node=rq-3")        ; det:until: on to an event
;;   (lab/checkpoint! s "here")
;;   (lab/compare! s {:kind "pause" :node "rq-2" :duration_ms 2000} {:ms 3000})
;;   (lab/close! s)
;;
;; A fault is det-faults' own request (guest/runtime/faults.zig's Request): {:kind :node :peer
;; :duration_ms :groups :direction :disruption :flavor :cpu_percent :skip_ms :forward :strobe_ms
;; :failure :delay_ms :nodes ...}, keys and values as det-faults names them. It applies while the
;; fault injector runs (the timeline's driver phase); a refusal is said in the action's result.
;;
;; What is derived and not read: which network faults are on, and until when, comes from the fault
;; events (their kind, nodes and duration), ended early by what heals them (a restore, a quiet
;; period's start, the injector's stop). The guest says no more than that today: a `det-faults
;; status` there would make it exact.
(ns determinismo.lab
  (:require [clojure.string :as str]
            [determinismo.api :as api]
            [determinismo.debug :as dbg]
            [determinismo.json :as json]
            [determinismo.tap :as tap]))

;; Saying times.

(defn secs
  "Nanoseconds as \"1.25 s\" (\"350 ms\" under a second)."
  [ns]
  (let [ns (* 1.0 ns)
        negative (neg? ns)
        size (if negative (- ns) ns)
        said (if (< size 1.0e9)
               (str (long (/ size 1.0e6)) " ms")
               (let [cs (long (/ size 1.0e7))]
                 (str (quot cs 100) "." (subs (str (+ 100 (mod cs 100))) 1) " s")))]
    (str (if negative "-" "") said)))

(defn at-said
  "A moment of a timeline, as seconds with three decimals."
  [ns]
  (let [ms (long (/ (* 1.0 ns) 1.0e6))]
    (str (quot ms 1000) "." (subs (str (+ 1000 (mod ms 1000))) 1) " s")))

;; The kinds of fault, by what they do.

(def network-kinds #{"isolate" "partition" "degrade" "partition_groups" "clog" "swizzle"})
(def down-kinds
  "Faults that take a node down until they end (it starts again then)."
  #{"restart" "crash" "stop" "wipe" "outage" "durable_crash"})
(def ^:private group-none 255)

;; A session's step and what it printed.

(defn- step-raw
  "One step of the session: its answer, {:output :done}."
  [session exec]
  (json/read-json (api/request :post (str "/sessions/" session "/step") {:exec exec})))

(def ^:private guest-prefix "[guest @ ")
(def ^:private moment-prefix "[determinismo] at moment vtime=")
(def ^:private until-prefix "[determinismo] until: ")
(def ^:private regs-prefix "[determinismo] regs: ")
(def ^:private skipped-prefixes ["{\"decision\"" "{\"event\":\"coverage\"" "{\"optimize\""])

(defn parse-output
  "What a step printed: the guest's events as the store has them ({:vtime_ns :event}: events,
  assertions, node output), the moment it ended at (:at-ns), what det:until matched (:until), the
  VMM's other lines (:said), and how many decisions and coverage lines went by (:passed)."
  [output]
  (reduce (fn [acc line]
            (cond
              (str/starts-with? line guest-prefix)
              (let [close (str/index-of line "ns] ")
                    text (when close (str/trim (subs line (+ close 4))))]
                (cond
                  (nil? text) acc
                  (some (fn [prefix] (str/starts-with? text prefix)) skipped-prefixes) (update acc :passed inc)
                  (str/starts-with? text "{") (let [at (parse-long (subs line (count guest-prefix) close))
                                                    parsed (try (json/read-json text) (catch #?(:jank jank.runtime.object_ref :default Exception) _ nil))]
                                                (if parsed
                                                  (update acc :events conj {:vtime_ns (* 1.0 at) :event parsed})
                                                  acc))
                  :else acc))
              (str/starts-with? line moment-prefix)
              (assoc acc :at-ns (* 1.0 (parse-long (re-find #"[0-9]+" (subs line (count moment-prefix))))))
              (str/starts-with? line until-prefix) (assoc acc :until (json/read-json (subs line (count until-prefix))))
              (str/starts-with? line "[determinismo] ") (update acc :said conj (str/trim line))
              :else acc))
          {:events [] :said [] :passed 0 :at-ns nil :until nil}
          (str/split-lines (or output ""))))

(defn- regs-of [output]
  (some (fn [line] (when (str/starts-with? line regs-prefix) (json/read-json (subs line (count regs-prefix)))))
        (str/split-lines (or output ""))))

;; An event's name and kind, whatever it is.

(defn event-name
  "An event's name: its event's, an assertion's message, or \"output\"."
  [e]
  (let [event (:event e)]
    (cond (:event event) (:event event)
          (:assert event) (get-in event [:assert :message])
          (:antithesis_assert event) (get-in event [:antithesis_assert :message])
          (:output event) "output"
          :else "?")))

(defn failed-assertion
  "The assertion an event is, when it failed: an always (or always-or-unreachable) false, or
  an unreachable reached. nil otherwise."
  [e]
  (let [a (or (get-in e [:event :assert]) (get-in e [:event :antithesis_assert]))]
    (when (and a (or (and (contains? #{"always" "alwaysOrUnreachable" "always_or_unreachable"} (:type a))
                          (false? (:condition a)))
                     (= "unreachable" (:type a))))
      a)))

;; The world: what the events say, folded in their order.

(def empty-world
  {:faults [] :clock-ns 0.0 :nodes {} :failing {} :history [] :running {} :quiet-until nil
   :injector nil :notes []})

(def ^:private kept-fault-keys
  [:kind :node :peer :groups :direction :disruption :flavor :cpu_percent :skip_ns :forward :strobe_ns
   :disk :outage :power :swizzle_order :injected :why :process :syscall :errno :one_in :after_sync])

(defn- trimmed
  "An endpoints' array without its trailing unused places (group-none, false, 0)."
  [values]
  (vec (reverse (drop-while (fn [v] (or (= v group-none) (false? v) (= v 0))) (reverse values)))))

(defn- compact
  "A fault event's details, what matters of them: the arrays its kind uses, trimmed, nothing
  empty."
  [details]
  (let [kind (:kind details)
        uses {:groups "partition_groups" :outage "outage" :power "outage" :swizzle_order "swizzle"}]
    (into {} (keep (fn [[k v]]
                     (cond (and (contains? uses k) (not= kind (get uses k))) nil
                           (or (nil? v) (= "" v) (false? v) (and (number? v) (zero? v))) nil
                           (and (= k :why) (= v "drawn")) nil
                           (sequential? v) [k (trimmed v)]
                           :else [k v]))
                   (select-keys details kept-fault-keys)))))

(defn- fault-of [at details]
  (assoc (compact details)
         :from-ns at
         :until-ns (when-not (:permanent details) (+ at (* 1.0 (or (:duration_ns details) 0))))))

(def ^:private history-max 200)
(def ^:private notes-max 40)

(defn- note [world at what]
  (update world :notes (fn [notes] (vec (take-last notes-max (conj notes {:at-ns at :what what}))))))

(defn- command-started [world at details]
  (update-in world [:running (str (:name details))] (fnil conj []) at))

(defn- command-ended [world at details]
  (let [name (str (:command details))
        started (get-in world [:running name])
        from (first started)]
    (-> world
        (assoc-in [:running name] (vec (rest started)))
        (update :history (fn [history]
                           (vec (take-last history-max
                                           (conj history {:command name :status (:status details)
                                                          :from-ns from :to-ns at}))))))))

(defn step-world
  "The world after one more event."
  [world e]
  (let [at (* 1.0 (:vtime_ns e))
        event (:event e)
        name (:event event)
        details (:details event)
        failed (failed-assertion e)]
    (cond
      failed
      (update-in world [:failing (:message failed)]
                 (fn [was] {:message (:message failed) :first-ns (or (:first-ns was) at) :last-ns at
                            :count (inc (or (:count was) 0)) :details (:details failed)}))

      (= name "fault")
      (let [kind (:kind details)]
        (cond
          (= kind "restore")
          (-> world
              (update :faults (fn [faults] (vec (remove (fn [f] (contains? network-kinds (:kind f))) faults))))
              (note at "restore: the network healed"))
          (and (= kind "clock_skip") (:permanent details))
          (update world :clock-ns + (* (if (:forward details) 1.0 -1.0) (or (:skip_ns details) 0)))
          :else (update world :faults conj (fault-of at details))))

      ;; A quiet period's start ends the fault under way, network and nodes (faults.zig's
      ;; quiet_request): only permanent clock skips stay.
      (= name "faults_quiet")
      (if (pos? (or (:duration_ns details) 0))
        (-> world
            (assoc :faults [] :quiet-until (+ at (* 1.0 (:duration_ns details))))
            (note at (str "quiet for " (secs (:duration_ns details)) ": faults healed")))
        world)
      (= name "faults_resume") (assoc world :quiet-until nil)
      (= name "faults_start") (assoc world :injector true)
      (= name "faults_stop") (-> world (assoc :faults [] :injector false) (note at "the fault injector stopped"))

      (contains? #{"node_kill" "node_crash" "node_stop" "node_wipe"} name)
      (assoc-in world [:nodes (:node details)] {:state :down :at-ns at :by name})
      (= name "node_start") (assoc-in world [:nodes (:node details)] {:state :up :at-ns at :by name})
      (= name "node_completed") (assoc-in world [:nodes (:node details)] {:state :halted :at-ns at :by name})
      (= name "node_disk_ended")
      (update world :faults (fn [faults] (vec (remove (fn [f] (and (= "disk" (:kind f)) (= (:node details) (:node f)))) faults))))

      (contains? #{"fault_inject_refused" "fault_skipped" "fault_failed"} name)
      (note world at (str (str/replace name "_" " ") ": " (or (:kind details) "") " " (or (:node details) "") " " (or (:err details) "")))

      (= name "command_start") (command-started world at details)
      (= name "command_exit") (command-ended world at details)
      :else world)))

(defn active-faults
  "The world's faults still on at `at-ns`."
  [world at-ns]
  (filterv (fn [f] (or (nil? (:until-ns f)) (> (:until-ns f) at-ns))) (:faults world)))

;; Links: each direction between two endpoints (the runner, where the test commands run, then
;; the nodes, in the system's order), as the faults on disrupt it.

(def link-states
  "From the most disrupted: cut (dropped), jammed (held, then delivered), clogged, slowed,
  degraded (delay, loss, duplicates, ...), ok."
  [:cut :jammed :clogged :slowed :degraded :ok])

(def ^:private severity (zipmap (reverse link-states) (range)))

(defn- disruption-state [f]
  (case (:disruption f) "jammed" :jammed "slowed" :slowed :cut))

(defn- direction-state
  "What fault `f` does to the direction from endpoint a to endpoint b (indices: the runner 0),
  or nil."
  [f index a b]
  (let [kind (:kind f)
        n (get index (:node f))
        p (get index (:peer f))]
    (cond
      (= kind "isolate") (when (or (= a n) (= b n)) :cut)
      (= kind "partition") (when (or (and (= a n) (= b p)) (and (= a p) (= b n))) :cut)
      (= kind "degrade") (when (and (= a n) (= b p)) :degraded)
      (= kind "partition_groups")
      (let [groups (:groups f)
            ga (get groups a group-none)
            gb (get groups b group-none)]
        (when (and (not= ga group-none) (not= gb group-none)
                   (case (or (:direction f) "both")
                     "outbound" (< ga gb)
                     "inbound" (> ga gb)
                     (not= ga gb)))
          (disruption-state f)))
      (= kind "clog")
      (when (case (or (:direction f) "both")
              "outbound" (= a n)
              "inbound" (= b n)
              (or (= a n) (= b n)))
        :clogged)
      ;; A swizzle clogs its nodes one after another, then unclogs them: drawn clogged all along.
      (= kind "swizzle")
      (let [order (:swizzle_order f)]
        (when (or (pos? (get order a 0)) (pos? (get order b 0))) :clogged))
      :else nil)))

(defn- worst [states]
  (if (seq states) (apply max-key severity states) :ok))

(defn endpoints
  "The runner, then the nodes."
  [names]
  (vec (cons "runner" names)))

(defn links
  "Every pair of endpoints with each direction's state and the faults on it:
  [{:a :b :ab :ba :faults}], the runner's first."
  [names faults]
  (let [all (endpoints names)
        index (zipmap all (range))]
    (vec (for [a (range (count all))
               b (range (inc a) (count all))
               :let [on (filterv (fn [f] (or (direction-state f index a b) (direction-state f index b a))) faults)]]
           {:a (nth all a) :b (nth all b)
            :ab (worst (keep (fn [f] (direction-state f index a b)) on))
            :ba (worst (keep (fn [f] (direction-state f index b a)) on))
            :faults on}))))

(defn- involves? [f name names]
  (let [index (zipmap (endpoints names) (range))
        i (get index name)]
    (or (= name (:node f)) (= name (:peer f))
        (and (:groups f) (not= group-none (get (:groups f) i group-none)))
        (and (:outage f) (true? (get (:outage f) i)))
        (and (:swizzle_order f) (pos? (get (:swizzle_order f) i 0))))))

(defn- groups-named
  "A partition's groups as names: given as names already, or as an event's endpoint array (the
  runner first, group-none for those left out)."
  [groups names]
  (cond (and (sequential? groups) (sequential? (first groups))) groups
        (and (sequential? groups) names)
        (let [all (endpoints names)]
          (->> (map-indexed vector groups)
               (remove (fn [[_ g]] (= g group-none)))
               (group-by second)
               (sort-by first)
               (mapv (fn [[_ members]] (mapv (fn [[i _]] (get all i (str "#" i))) members)))))
        :else nil))

(defn fault-said
  "A fault as a few words: its kind, its nodes, its parameters. `names`, the system's nodes,
  names an event's groups."
  ([f] (fault-said f nil))
  ([f names]
  (let [kind (str (:kind f))
        groups (groups-named (:groups f) names)]
    (str kind
         (when (seq (str (:node f))) (str " " (:node f)))
         (when (seq (str (:peer f))) (str " " (:peer f)))
         (when (seq groups)
           (str " " (str/join " | " (map (fn [g] (str/join " " g)) groups))))
         (when (and (:direction f) (not= "both" (:direction f))) (str " " (:direction f)))
         (when (and (:disruption f) (not= "stopped" (:disruption f))) (str " " (:disruption f)))
         (when (:flavor f) (str " " (:flavor f)))
         (when (:cpu_percent f) (when (pos? (:cpu_percent f)) (str " " (:cpu_percent f) "%")))
         (when (:failure f) (str " " (:failure f)))
         (when (:disk f) (str " " (get-in f [:disk :failure])))
         (when (:skip_ms f) (str " " (if (false? (:forward f)) "-" "+") (:skip_ms f) " ms"))
         (when (and (:skip_ns f) (pos? (:skip_ns f))) (str " " (if (:forward f) "+" "-") (secs (:skip_ns f))))
         (when (:duration_ms f) (str " for " (secs (* 1.0e6 (:duration_ms f)))))
         (when (:duration_ns f) (str " for " (secs (:duration_ns f))))))))

(def ^:private short-kinds
  {"partition_groups" "partition" "process_pause" "process paused" "thread_pause" "thread paused"
   "process_kill" "process killed" "syscall_error" "syscall errors" "file_error" "file errors"})

(defn- badges
  "What a node shows: its clock, disk and CPU first, then every fault on it with the time it has
  left (one the lab or the scenario asked for marked *)."
  [name names faults at]
  (let [on (filterv (fn [f] (involves? f name names)) faults)
        left (fn [f] (if (:until-ns f) (str (secs (- (:until-ns f) at)) " left") "for good"))]
    (vec (concat
          (for [f on :when (= "clock_skew" (:kind f))]
            {:kind :clock :said (str "clock " (if (:forward f) "+" "-") (secs (:skip_ns f))
                                     (when (pos? (or (:strobe_ns f) 0)) (str " strobe " (secs (:strobe_ns f)))))
             :left (left f)})
          (for [f on :when (= "disk" (:kind f))]
            {:kind :disk :said (str "disk " (get-in f [:disk :failure])) :left (left f)})
          (for [f on :when (contains? #{"sync_stall" "durable_crash"} (:kind f))]
            {:kind :disk :said (if (= "sync_stall" (:kind f)) "syncs held" "crash at a sync") :left (left f)})
          (for [f on :when (= "throttle" (:kind f))]
            {:kind :cpu :said (str "cpu " (:cpu_percent f) "%") :left (left f)})
          (for [f on :when (not (contains? #{"clock_skew" "disk" "sync_stall" "durable_crash" "throttle"} (:kind f)))]
            {:kind :fault :said (str (get short-kinds (:kind f) (:kind f)) (when (:injected f) "*")) :left (left f)})))))

(defn- node-state
  "up, paused, down (by a fault, or an end the events say, until it starts again) or halted
  (stopped with nothing that ended it: its own exit, or never started)."
  [world procs name names faults]
  (let [proc (get procs name)
        on (filter (fn [f] (involves? f name names)) faults)
        paused (or (= proc "paused") (some (fn [f] (and (= "pause" (:kind f)) (= name (:node f)))) on))
        by-fault (some (fn [f] (contains? down-kinds (:kind f))) on)
        ended (= :down (get-in world [:nodes name :state]))]
    (cond paused :paused
          (= proc "running") :up
          (or by-fault ended) :down
          (= proc "stopped") :halted
          (= :halted (get-in world [:nodes name :state])) :halted
          :else :up)))

(defn view
  "The world of a lab at its moment, as data to draw or read: {:at-ns :nodes [{:name :state
  :badges}] :links [...] :faults [...] :clock-ns :quiet :injector :failing [...] :history [...]}."
  [lab]
  (let [world (:world lab)
        at (:at-ns lab)
        names (:names lab)
        faults (active-faults world at)
        procs (:procs lab)]
    {:lab/world true
     :session (:session lab) :timeline (:timeline lab) :run (:run lab) :branch (:branch lab)
     :at-ns at
     :nodes (mapv (fn [name] {:name name :state (node-state world procs name names faults)
                              :pid (get-in lab [:pids name])
                              :badges (badges name names faults at)})
                  names)
     :links (links names faults)
     :faults (mapv (fn [f] (assoc f :said (fault-said f names) :left-ns (when (:until-ns f) (- (:until-ns f) at)))) faults)
     :clock-ns (:clock-ns world)
     :quiet (when (and (:quiet-until world) (> (:quiet-until world) at)) (- (:quiet-until world) at))
     :injector (:injector world)
     :failing (vec (sort-by :first-ns (vals (:failing world))))
     :history (vec (take-last 12 (:history world)))
     :running (into {} (keep (fn [[k v]] (when (seq v) [k (count v)])) (:running world)))
     :notes (vec (take-last 6 (:notes world)))}))

;; The lab: one session at a time (a session is a machine), held here and followed by the viz.

(defonce ^{:doc "The lab: the session's world, its last action and what it did, its checkpoints,
  a comparison's diff. nil without one."} state (atom nil))

(defonce ^:private opened (atom {}))

(defn- heard [kind data]
  (when (= kind :session/open)
    (swap! opened assoc (:session data) {:run (:run data) :branch (:branch data)})))

(defonce ^:private listening (do (tap/listen! (fn [kind data] (heard kind data))) true))

(defn- lab-of [session]
  (let [lab @state]
    (when-not (and lab (= session (:session lab)))
      (throw (ex-info (str "determinismo: the lab is not on session " session " (attach! it)")
                      {:session session :lab (:session lab)})))
    lab))

(defn- moment-of [session]
  (* 1.0 (:vtime_ns (regs-of (:output (step-raw session "det:regs"))))))

(def ^:private watched-names
  ["fault" "faults_quiet" "faults_resume" "faults_start" "faults_stop" "node_kill" "node_crash"
   "node_stop" "node_start" "node_wipe" "node_completed" "node_disk_ended" "command_start"
   "command_exit"])

(def ^:private before-window-ns 300.0e9)

(defn- before-events
  "The timeline's events that make the world at `at-ns`: the faults, quiet periods, node starts
  and ends and test commands of the last 300 s, its failed assertions, from the run's store."
  [run branch at-ns]
  (let [from (max 0.0 (- at-ns before-window-ns))
        rows (api/request :post (str "/runs/" run "/sql")
                          {:sql (str "SELECT vtime_ns, event FROM timeline_events WHERE timeline = " branch
                                     " AND vtime_ns <= " (long at-ns) " AND ((vtime_ns >= " (long from)
                                     " AND name IN (" (str/join "," (map (fn [n] (str "'" n "'")) watched-names)) "))"
                                     " OR (kind = 'assert' AND condition = false AND type IN ('always', 'alwaysOrUnreachable')))"
                                     " ORDER BY vtime_ns, seq")})
        parsed (json/read-json rows)]
    (mapv (fn [row] {:vtime_ns (* 1.0 (:vtime_ns row)) :event (:event row)})
          (if (map? parsed) [parsed] parsed))))

(defn- notable?
  "An event shown among those since the last action: not a test command's start or end, not a
  node's sample."
  [e]
  (let [name (event-name e)]
    (not (contains? #{"command_start" "command_exit" "node_sample" "output" "stdout" "stderr" "exec_start"
                      "exec_done" "exec_output"} name))))

(def ^:private since-max 60)
(def ^:private output-max 16)

(defn- took
  "What steps printed, into the lab: the world after their events, the moment they ended at,
  what happened since the action began (notable events, node output, counts by name)."
  [lab parsed]
  (let [events (:events parsed)
        counts (reduce (fn [m e] (update m (event-name e) (fnil inc 0))) (:since-counts lab) events)]
    (-> lab
        (assoc :world (reduce step-world (:world lab) events))
        ;; Where the step ended: the VMM says it after a wait; after a guest command, its last
        ;; event's moment is the nearest known.
        (assoc :at-ns (max (:at-ns lab) (or (:at-ns parsed) 0.0) (or (some-> (last events) :vtime_ns) 0.0)))
        (assoc :since-counts (if (pos? (:passed parsed)) (update counts "decisions and coverage" (fnil + 0) (:passed parsed)) counts))
        (update :since (fn [since] (vec (take-last since-max (concat since (filter notable? events))))))
        (update :output (fn [lines] (vec (take-last output-max (concat lines (filter (fn [e] (get-in e [:event :output])) events)))))))))

(defn- step!
  "One step of the lab's session, taken into the lab. -> the step's parsed output."
  [session exec]
  (let [answer (step-raw session exec)
        parsed (parse-output (:output answer))]
    (swap! state (fn [lab] (if (= session (:session lab)) (cond-> (took lab parsed) (:done answer) (assoc :ended true)) lab)))
    (when (:done answer)
      (throw (ex-info (str "determinismo: the session ended at its step " exec) {:session session :said (:said parsed)})))
    parsed))

(def ^:private exec-output-prefix "{\"event\":\"exec_output\"")

(defn- procs!
  "The nodes' processes now (det-nodes list, a guest command: the guest runs while it does)."
  [session]
  (let [parsed (step! session "det-nodes list")
        text (apply str (keep (fn [e] (when (= "exec_output" (get-in e [:event :event])) (get-in e [:event :details :text])))
                              (:events parsed)))
        listed (keep (fn [line] (when (str/starts-with? line "{") (json/read-json line))) (str/split-lines text))]
    (swap! state (fn [lab]
                   (if (= session (:session lab))
                     (assoc lab
                            :procs (into {} (map (fn [n] [(:name n) (:state n)]) listed))
                            :pids (into {} (map (fn [n] [(:name n) (:pid n)]) listed)))
                     lab)))
    listed))

(defn- begin!
  "An action starts: one at a time (a session answers one request at a time), what happened
  since the last one forgotten."
  [session what]
  (let [lab (lab-of session)]
    (when (or (:busy lab)
              (not (compare-and-set! state lab (assoc lab :busy what :since [] :since-counts {} :output []
                                                      :mark-ns (:at-ns lab)))))
      (throw (ex-info (str "determinismo: the lab is busy: " (:busy @state)) {:busy (:busy @state)})))))

(defn- finish!
  "An action ended (or failed): noted with what came of it, the nodes read again."
  [session what result]
  (try
    (when-not (:ended @state) (procs! session))
    (finally
      (swap! state (fn [lab]
                     (if (= session (:session lab))
                       (-> lab
                           (dissoc :busy)
                           (update :actions (fn [actions] (vec (take-last 30 (conj actions (merge {:what what :from-ns (:mark-ns lab)
                                                                                                   :to-ns (:at-ns lab)}
                                                                                                  result)))))))
                       lab))))))

(defn- acted
  "An action's result, as the REPL and the viz show it."
  [session what extra]
  (let [lab @state]
    (merge {:lab/act what :session session :timeline (:timeline lab)
            :from-ns (:mark-ns lab) :at-ns (:at-ns lab)
            :events (:since lab) :counts (:since-counts lab)
            :failing (keys (:failing (:world lab)))}
           extra)))

(defn- act!
  "An action: `steps` in order on the session, the nodes read after. `result` (fn [parsed
  outputs]) says what came of it. -> the action's result."
  [session what steps result]
  (begin! session what)
  (let [outcome (atom {})]
    (try
      (let [parsed (mapv (fn [exec] (step! session exec)) steps)]
        (reset! outcome (or (result parsed) {}))
        (acted session what @outcome))
      (catch #?(:jank jank.runtime.object_ref :default Exception) e
        (reset! outcome {:error (or (ex-message e) (str e))})
        (throw e))
      (finally (finish! session what @outcome)))))

;; Opening and attaching.

(defn attach!
  "The lab on session `session`, at its moment (opened by determinismo.debug/open, `open!` or
  `resume`): the world there, from the timeline's events before the moment (the run's store),
  then the nodes' processes as det-nodes reads them. `world` given: that one instead of the
  store's (a checkpoint's, carried over). -> the world, as `view` says it."
  ([session] (attach! session nil))
  ([session world]
   (let [{:keys [run branch]} (or (get @opened session)
                                  (throw (ex-info (str "determinismo: session " session " was not opened from this REPL") {:session session})))
         at (moment-of session)
         info (api/run run)
         names (mapv :name (get-in info [:run :system :nodes]))
         world (or world (reduce step-world (assoc empty-world :injector nil) (before-events run branch at)))]
     (reset! state {:session session :run run :branch branch :timeline (dbg/timeline session)
                    :names names :scenario (get-in info [:run :scenario])
                    :at-ns at :opened-ns at :mark-ns at :world world
                    :since [] :since-counts {} :output [] :actions [] :checkpoints (or (:checkpoints @state) [])})
     (procs! session)
     (let [seen (view @state)]
       (tap/tell :lab/attach {:session session :run run :branch branch :at-ns at} seen)))))

(defn open!
  "A session at a moment of `run`'s timeline (determinismo.debug/open's options: {:branch
  :at-vtime-ms} or {:branch :until :rewind-ms}), the lab on it. -> the session."
  [run options]
  (let [session (dbg/open run options)]
    (attach! session)
    session))

(defn world
  "The lab's world at its moment: nodes (up, paused, down, halted) with their badges, links
  with each direction's state, the faults on, failed properties, the test commands' last
  outcomes."
  ([] (some-> @state view))
  ([session] (view (lab-of session))))

;; Acting.

(defn- spec-json
  "A fault as det-faults' JSON: keywords as their names."
  [spec]
  (json/write-json (into {} (map (fn [[k v]] [k (if (keyword? v) (name v) v)]) spec))))

(defn inject-command
  "The guest command that asks the running fault injector for `spec` now."
  [spec]
  (str "det-faults inject '" (str/replace (spec-json spec) "'" "'\\''") "'"))

(defn- refusal
  "Why det-faults did not apply the fault, from the step's output, or nil."
  [parsed]
  (let [events (:events parsed)
        said (apply str (keep (fn [e] (when (= "exec_output" (get-in e [:event :event])) (get-in e [:event :details :text]))) events))
        refused (some (fn [e] (when (= "fault_inject_refused" (get-in e [:event :event])) (get-in e [:event :details]))) events)]
    (cond refused (str "refused: " (or (:err refused) "") (when (:kind refused) (str " (" (:kind refused) ")")))
          (str/includes? said "no fault injector is running") "no fault injector is running (faults apply while drivers run)"
          (some (fn [e] (and (= "exec_done" (get-in e [:event :event])) (not= 0 (get-in e [:event :details :status])))) events)
          (str "det-faults failed: " (str/trim said))
          :else nil)))

(def ^:private applied-wait-ms
  "How long `fault!` waits for its fault's event: the injector applies a node fault after the
  command that asked for it returns."
  1000)

(defn- injected-event
  "The fault an action's events say was applied for it (the injected one of its kind), or why it
  was not."
  [events spec]
  (let [mine (fn [d] (and (= (name (:kind spec)) (:kind d))
                          (or (nil? (:node spec)) (= "" (:node d)) (= (:node spec) (:node d)))))]
    (or (some (fn [e] (let [d (get-in e [:event :details])]
                        (when (and (= "fault" (get-in e [:event :event])) (:injected d) (mine d)) {:applied (compact d)})))
              events)
        (some (fn [e] (let [d (get-in e [:event :details])
                            n (get-in e [:event :event])]
                        (when (and (contains? #{"fault_skipped" "fault_failed"} n)
                                   (or (nil? (:kind d)) (= (name (:kind spec)) (:kind d)))
                                   (or (nil? (:node d)) (nil? (:node spec)) (= (:node spec) (:node d))))
                          {:refused (str (str/replace n "_" " ") ": " (:err d))})))
              events))))

(defn fault!
  "A fault now, on the session's timeline: `det-faults inject` with `spec` (det-faults' request:
  {:kind \"partition_groups\" :groups [[\"a\"] [\"b\" \"c\"]] :direction \"outbound\" :duration_ms
  3000}, {:kind \"pause\" :node \"a\" :duration_ms 2000}, {:kind \"clock_skew\" :node \"a\" :skip_ms
  300 :forward false}, {:kind \"disk\" :node \"a\" :failure \"lost_writes\"}, ...), then on until
  its event says it applied (det:until, 1 s at most: the injector applies a node fault after the
  command returns). Steps, so recorded and replayed with the timeline. -> {:lab/act :applied
  (the fault event's details) :refused}"
  [session spec]
  (let [what (str "fault " (fault-said spec))
        until (str "event=fault details.kind=" (name (:kind spec))
                   (when (seq (str (:node spec))) (str " details.node=" (:node spec))))]
    (begin! session what)
    (let [outcome (atom {:fault spec})]
      (try
        (let [asked (step! session (inject-command spec))
              refused (refusal asked)
              found (when-not refused
                      (or (injected-event (:events asked) spec)
                          (let [waited (step! session (str "det:until " applied-wait-ms " " until))]
                            (or (injected-event (concat (:events asked) (:events waited)) spec)
                                {:refused (str "no fault event within " applied-wait-ms " ms (a quiet period, or a fault of its layer under way)")}))))]
          (swap! outcome merge (if refused {:refused refused} found))
          (acted session what @outcome))
        (catch #?(:jank jank.runtime.object_ref :default Exception) e
          (swap! outcome assoc :error (or (ex-message e) (str e)))
          (throw e))
        (finally (finish! session what @outcome))))))

(defn advance!
  "The session's timeline `ms` further (det:wait): what happened meanwhile. -> {:lab/act ...}"
  [session ms]
  (act! session (str "advance " (secs (* 1.0e6 ms))) [(str "det:wait " (long ms))] (fn [_] {:ms ms})))

(def ^:private until-ms-default 60000)

(defn until!
  "The session's timeline on until an event matches `condition` (the query language:
  \"event=node_start details.node=rq-3\"), `max-ms` at most (60 s): det:until, stopped just after
  the event. -> {:lab/act :matched (the event, or nil when the time ran out)}"
  ([session condition] (until! session condition until-ms-default))
  ([session condition max-ms]
   (act! session (str "until " condition) [(str "det:until " (long max-ms) " " condition)]
         (fn [[parsed]] {:condition condition :matched (:until parsed)}))))

(defn checkpoint!
  "The machine saved at the session's moment (determinismo.debug/checkpoint): `resume` opens a
  session there again. -> {:name :vtime_ns :saved}"
  [session name]
  (let [lab (lab-of session)
        found (dbg/checkpoint session name)]
    (swap! state (fn [lab]
                   (-> lab
                       (update :checkpoints conj (assoc found :timeline (:timeline lab) :session session
                                                        :world (:world lab) :names (:names lab)))
                       (assoc :at-ns (max (:at-ns lab) (* 1.0 (:vtime_ns found)))))))
    found))

(defn close!
  "The session ended (its machine stopped), the lab with it."
  [session]
  (let [ended (dbg/close session)]
    (swap! state (fn [lab] (if (= session (:session lab)) (assoc lab :closed true) lab)))
    ended))

;; A fault against the same moment without it.

(defn- events-key
  "An event as compared between two futures: its name and details, not its moment."
  [e]
  [(event-name e) (get-in e [:event :details]) (get-in e [:event :assert :condition]) (get-in e [:event :output :text])])

(defn- variant
  "One future from a checkpoint: a session resumed there, the lab carried over, `exec` then `ms`
  of the timeline. -> {:session :timeline :events (those of the `ms`, compared) :applied (the
  fault `exec` applied, if any) :lab}"
  [run session name world label exec ms]
  (let [resumed (dbg/resume run session name)
        _ (attach! resumed world)
        done (atom nil)]
    (begin! resumed label)
    (try
      (let [first-step (step! resumed exec)
            waited (step! resumed (str "det:wait " (long ms)))]
        (reset! done {:events (vec (remove (fn [e] (and (= "fault" (get-in e [:event :event])) (get-in e [:event :details :injected])))
                                           (:events waited)))
                      :applied (some (fn [e] (when (and (= "fault" (get-in e [:event :event])) (get-in e [:event :details :injected]))
                                               (compact (get-in e [:event :details]))))
                                     (concat (:events first-step) (:events waited)))
                      :refused (refusal first-step)}))
      (finally (finish! resumed label {})))
    (assoc @done :session resumed :timeline (dbg/timeline resumed) :lab @state)))

(defn- outcomes [lab from]
  (let [done (filter (fn [h] (and (:to-ns h) (>= (:to-ns h) from))) (:history (:world lab)))]
    {:ok (count (filter (fn [h] (= 0 (:status h))) done))
     :failed (count (remove (fn [h] (= 0 (:status h))) done))
     :failures (vec (take 6 (map (fn [h] (str (:command h) " " (:status h))) (remove (fn [h] (= 0 (:status h))) done))))}))

(defn diff
  "What a fault changed: `with` against `without`, two futures of the same checkpoint (each
  {:events :lab}): the failed properties new and gone, the test commands' outcomes, the events
  by name, the end state of the nodes, and where the two futures first part."
  [without with from-ns]
  (let [notable (fn [v] (filterv (fn [e] (not (contains? #{"exec_start" "exec_done" "exec_output"} (event-name e)))) (:events v)))
        a (notable without)
        b (notable with)
        failing (fn [v] (set (map :message (keep failed-assertion (:events v)))))
        fa (failing without)
        fb (failing with)
        count-of (fn [events] (frequencies (map event-name events)))
        ca (count-of a)
        cb (count-of b)
        names (distinct (concat (keys ca) (keys cb)))
        by-name (->> names
                     (map (fn [n] {:name n :without (get ca n 0) :with (get cb n 0)}))
                     (remove (fn [row] (= (:without row) (:with row))))
                     (sort-by (fn [row] (- (abs (- (:with row) (:without row))))))
                     vec)
        parted (first (keep-indexed (fn [i [x y]] (when (not= (events-key x) (events-key y)) i)) (map vector a b)))
        said (fn [e] (when e (str (at-said (:vtime_ns e)) " " (event-name e)
                                  (when-let [d (get-in e [:event :details])] (str " " (pr-str (select-keys d [:node :kind :command :status :name])))))))
        states (fn [v] (into {} (map (fn [n] [(:name n) (:state n)]) (:nodes (view (:lab v))))))]
    {:lab/diff true
     :from-ns from-ns
     :failing {:new (vec (sort (remove fa fb))) :gone (vec (sort (remove fb fa))) :both (vec (sort (filter fa fb)))}
     :history {:without (outcomes (:lab without) from-ns) :with (outcomes (:lab with) from-ns)}
     :events by-name
     :counts {:without (count a) :with (count b)}
     :parted (if parted
               {:index parted :without (said (nth a parted nil)) :with (said (nth b parted nil))
                :at-ns (min (* 1.0 (:vtime_ns (nth a parted))) (* 1.0 (:vtime_ns (nth b parted))))}
               (when (not= (count a) (count b)) {:index (min (count a) (count b)) :without (said (nth a (count b) nil)) :with (said (nth b (count a) nil))}))
     :nodes {:without (states without) :with (states with)}
     :timelines {:without (:timeline without) :with (:timeline with)}}))

(defn compare!
  "What `fault` changes at the session's moment: the moment checkpointed, then futures of it,
  each a session resumed from the checkpoint (one at a time): without the fault (`true`, a guest
  command in its place) and with it, each run on `:ms` (3 s) of the timeline after that step;
  what each did in those `:ms` compared. With `:control true`, a second future without the fault
  first: whether two futures with the same steps are the same (the comparison's noise floor).
  The session given is closed; the lab goes on in the future with the fault. -> the diff, with
  :session (the lab's session now) and the futures' timelines, which stay in the run as any
  session's do."
  ([session fault] (compare! session fault {}))
  ([session fault {:keys [ms name control] :or {ms 3000}}]
   (let [lab (lab-of session)
         run (:run lab)
         name (or name (str "lab-" (:timeline lab) "-" (inc (count (:checkpoints lab)))))
         found (checkpoint! session name)
         world (:world @state)
         _ (close! session)
         again (when control
                 (let [v (variant run session name world "without the fault (control)" "true" ms)]
                   (close! (:session v))
                   v))
         without (variant run session name world "without the fault" "true" ms)
         _ (close! (:session without))
         with (variant run session name world (str "with " (fault-said fault)) (inject-command fault) ms)
         made (cond-> (assoc (diff without with (* 1.0 (:vtime_ns found)))
                             :fault fault :said (fault-said fault) :ms ms :checkpoint name
                             :applied (:applied with) :refused (:refused with)
                             :session (:session with))
                again (assoc :control (let [d (diff again without (* 1.0 (:vtime_ns found)))]
                                        {:same (and (nil? (:parted d)) (empty? (:events d)))
                                         :parted (:parted d) :events (count (:events again))
                                         :timeline (:timeline again)})))]
     (swap! state assoc :diff made)
     (tap/tell :lab/compare made made))))
