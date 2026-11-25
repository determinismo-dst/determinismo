;; SPDX-License-Identifier: MIT
;; A Lean replica's counterexample driven against the real system (sdk/lean: a system's code
;; modeled in Lean 4 in determinismo's chaotic world). The counterexample is a tape, JSON lines
;; of decisions {"name", "options", "value"} (Determinismo/Decide.lean), and beside it, often, its
;; story (`<name>.story.txt`: a line an event, "12: node 2 lost power"). Its fault decisions
;; (Determinismo/Cluster.lean's fault.crash, fault.kill, fault.partition.*, fault.clock.*, the
;; replicas' fault.pause.* and fault.crash_point, disk.sync.error) become det-faults requests on a
;; session of a real run, given which real node each model node is; the rest of the tape (which
;; message is delivered, which node ticks, a client's operation, the model's disk) is the real
;; system's own to decide and is listed as skipped, never faked.
;;
;;   (require '[determinismo.lean :as lean] '[determinismo.lab :as lab])
;;   (def s (lab/open! 2163 {:branch 0 :at-vtime-ms 30000}))
;;   (lean/load! ".../H1-bootstrap-split-brain.tape.jsonl" {:nodes ["rq-1" "rq-2" "rq-3"]})
;;   (lean/next! s)     ; the next fault, then the timeline on to the one after it
;;   (lean/drive! s)    ; the rest, one at a time
;;
;; Which model node a decision names: `pick` draws an index into the nodes up (Decide.lean), so
;; the decoder follows which are up through the tape's own kills, power losses and starts. A
;; node's code can halt it with no decision on the tape, and a start among one node down is not
;; recorded (one option): an index that no longer fits is a node the tape alone does not name.
;; The story names each one; with it, the faults are its lines', and their lengths its steps'.
(ns determinismo.lean
  (:require [clojure.string :as str]
            [determinismo.json :as json]
            [determinismo.lab :as lab]
            [determinismo.tap :as tap]))

(defn read-tape
  "A tape's decisions, in order: [{:index :name :options :value}]."
  [path]
  (->> (str/split-lines (slurp path))
       (remove str/blank?)
       (map-indexed (fn [i line] (assoc (json/read-json line) :index i)))
       vec))

(defn- numbers [text]
  (mapv parse-long (re-seq #"[0-9]+" (or text ""))))

(def ^:private story-lines
  "A story's fault lines: a pattern and what a match says."
  [[#"^([0-9]+): node ([0-9]+) killed$" (fn [[_ step n]] {:kind :kill :node (parse-long n)})]
   [#"^([0-9]+): node ([0-9]+) lost power$" (fn [[_ step n]] {:kind :crash :node (parse-long n)})]
   [#"^([0-9]+): node ([0-9]+) started$" (fn [[_ step n]] {:kind :start :node (parse-long n)})]
   [#"^([0-9]+): partition: \[([0-9, ]*)\] from \[([0-9, ]*)\]( \(one way\))?$"
    (fn [[_ step side rest one-way]] {:kind :partition :side (numbers side) :rest (numbers rest) :one-way (some? one-way)})]
   [#"^([0-9]+): partition healed$" (fn [_] {:kind :heal})]
   [#"^([0-9]+): node ([0-9]+): goroutine ([0-9]+) paused for ([0-9]+) ticks$"
    (fn [[_ step n g t]] {:kind :pause :node (parse-long n) :goroutine (parse-long g) :ticks (parse-long t)})]
   [#"^([0-9]+): node ([0-9]+)'s clock skewed (-?[0-9]+)$" (fn [[_ step n s]] {:kind :skew :node (parse-long n) :skew (parse-long s)})]
   [#"^([0-9]+): node ([0-9]+): sync of (.+) failed$" (fn [[_ step n file]] {:kind :sync-error :node (parse-long n) :file file})]
   [#"^([0-9]+): node ([0-9]+) halted: (killed|power lost) at (.*)$"
    (fn [[_ step n how point]] {:kind :crash-point :node (parse-long n) :power (= how "power lost") :point point})]
   [#"^([0-9]+): node ([0-9]+) halted: (.*)$" (fn [[_ step n why]] {:kind :halt :node (parse-long n) :why why})]])

(defn read-story
  "A story's fault lines, in order: [{:step :kind :node ...}] (kinds :kill :crash :start
  :partition :heal :pause :skew :sync-error :crash-point :halt); its other lines left out."
  [path]
  (vec (keep (fn [line]
               (some (fn [[pattern said]]
                       (when-let [m (re-find pattern line)]
                         (assoc (said m) :step (parse-long (second m)) :line line)))
                     story-lines))
             (str/split-lines (slurp path)))))

(def defaults
  "How the model's time becomes the real system's: a tick (fault.pause.ticks, fault.clock.skew),
  a step of the story (an event: the gap between two faults, a fault's length to its end), and
  the lengths used without a story."
  {:tick-ms 100 :ms-per-step 20 :gap-ms-min 200 :gap-ms-max 10000 :between-ms 1000
   :down-ms 2000 :partition-ms 3000 :clock-ms 5000 :sync-error-ms 500})

(defn- skip-reason
  "Why a decision is not driven."
  [name]
  (cond
    (str/starts-with? name "net.") "a message delivered, dropped or duplicated, or a connection: the real network decides"
    (str/starts-with? name "world.swarm.") "the timeline's fault kinds (swarm testing): which kinds the tape draws"
    (= name "world.start") "a node started again: the end of the fault before it (its length)"
    (str/starts-with? name "world.") "which event comes next: the real system's scheduling"
    (str/starts-with? name "node.") "a node's own randomness or scheduling (a timeout's jitter, a goroutine): the real node's"
    (str/starts-with? name "client.") "a client's operation: the real run's drivers"
    (str/starts-with? name "disk.") "the model's disk (what a crash keeps, writeback): the real disk decides"
    (= name "fault.evict") "no determinismo fault is known for it (no Lean replica in reach draws it)"
    (str/starts-with? name "fault.") "a fault decision this decoder does not know"
    :else "the model's own (no fault)"))

(def ^:private one-by-one
  "Decisions listed one by one when skipped (the rest are counted by name)."
  #{"net.drop" "net.duplicate" "net.conn.break" "world.start" "fault.evict" "disk.sync.error"
    "fault.crash_point" "fault.kill" "fault.crash" "fault.pause.node" "fault.clock.node"
    "fault.partition.side"})

(defn- mapped-name [nodes n]
  (get (if (map? nodes) nodes (zipmap (range) nodes)) n))

(defn- clamp [x lo hi] (max lo (min hi x)))

(defn- gap-ms
  "The real time from a story step to another."
  [options from to]
  (clamp (* (:ms-per-step options) (max 1 (- to from))) (:gap-ms-min options) (:gap-ms-max options)))

(defn- ending
  "The story's first note after position `at` that ends a fault: (pred note)."
  [notes at pred]
  (first (filter pred (drop (inc at) notes))))

(defn plan
  "The faults of `tape` (its decisions) as det-faults requests against the real nodes `nodes`
  (model node n -> a real node's name: a vector or a map), one step each with how long to let the
  timeline run after it; `story` (its notes, `read-story`) names the nodes the tape alone does not
  and gives the lengths. -> {:steps [{:index :decision :model :inject :wait-ms :certain}]
  :skipped [{:index :name :value :why}] :counted {name count} :disagree [...]}"
  ([tape nodes] (plan tape nodes nil {}))
  ([tape nodes story options]
   (let [options (merge defaults options)
         n (count nodes)
         names (fn [ns] (mapv (fn [m] (mapped-name nodes m)) ns))
         decisions (vec tape)
         notes (vec story)
         ;; Each kind's notes in order, with where each is in the story.
         queue (group-by :kind (map-indexed (fn [i note] (assoc note :at i)) notes))
         taken (atom {})
         take-note! (fn [kind]
                      (let [i (get @taken kind 0)
                            note (get (get queue kind) i)]
                        (swap! taken assoc kind (inc i))
                        note))
         out (atom {:steps [] :skipped [] :counted {} :disagree []})
         skip! (fn [d why]
                 (if (contains? one-by-one (:name d))
                   (swap! out update :skipped conj (assoc (select-keys d [:index :name :options :value]) :why why))
                   (swap! out update-in [:counted (:name d)] (fnil inc 0))))
         step! (fn [d model inject note certain fallback-ms end]
                 (let [wait (if note
                              (let [next-fault (first (filter (fn [x] (contains? #{:kill :crash :partition :pause :skew :sync-error :crash-point} (:kind x)))
                                                              (drop (inc (:at note)) notes)))]
                                (if next-fault (gap-ms options (:step note) (:step next-fault)) (:between-ms options)))
                              (:between-ms options))
                       length (if (and note end) (gap-ms options (:step note) (:step end)) fallback-ms)]
                   (swap! out update :steps conj
                          {:index (:index d) :decision (:name d) :model model :certain certain
                           :step (:step note) :wait-ms wait
                           :inject (cond-> inject (and length (not (contains? inject :duration_ms))) (assoc :duration_ms length))})))
         ;; Which model node an index into the nodes up names: certain when the options are as
         ;; many as the nodes the tape says are up, or all of them (the ones down started again).
         up-pick (fn [up d]
                   (cond (= (:options d) (count up)) [(nth (vec (sort up)) (:value d)) up]
                         (= (:options d) n) [(:value d) (set (range n))]
                         :else [nil up]))]
     (loop [i 0 up (set (range n))]
       (if (>= i (count decisions))
         @out
         (let [d (nth decisions i)
               name (:name d)
               following (get decisions (inc i))]
           (cond
             (contains? #{"fault.kill" "fault.crash"} name)
             (let [[picked up] (up-pick up d)
                   note (take-note! (if (= name "fault.kill") :kill :crash))
                   node (or (:node note) picked)
                   real (mapped-name nodes node)]
               (when (and note picked (not= picked (:node note)))
                 (swap! out update :disagree conj {:index (:index d) :tape picked :story (:node note)}))
               (if real
                 (step! d (str "node " node (if (= name "fault.kill") " killed" " lost power"))
                        {:kind (if (= name "fault.kill") "restart" "crash") :node real}
                        note (or (some? note) (= (:options d) n)) (:down-ms options)
                        (when note (ending notes (:at note) (fn [x] (and (= :start (:kind x)) (= node (:node x)))))))
                 (skip! d "which node: the tape alone does not say (a node halted by its own code, or a start not recorded): give the story"))
               (recur (inc i) (if node (disj up node) up)))

             (= name "world.start")
             (let [down (vec (sort (remove up (range n))))
                   node (when (= (:options d) (count down)) (nth down (:value d)))]
               (skip! d (skip-reason name))
               (recur (inc i) (if node (conj up node) up)))

             (= name "fault.partition.side")
             (let [mask (inc (:value d))
                   side (filterv (fn [m] (bit-test mask m)) (range n))
                   rest (filterv (fn [m] (not (bit-test mask m))) (range n))
                   one-way-decision (when (= "fault.partition.one_way" (:name following)) following)
                   one-way (= 1 (:value one-way-decision))
                   note (take-note! :partition)
                   end (when note (ending notes (:at note) (fn [x] (= :heal (:kind x)))))]
               (when (and note (not= side (:side note)))
                 (swap! out update :disagree conj {:index (:index d) :tape side :story (:side note)}))
               (if (some nil? (names (concat side rest)))
                 (skip! d "a model node with no real node given")
                 (step! d (str "partition " side " from " rest (when one-way " (one way)"))
                        {:kind "partition_groups" :groups [(names side) (names rest)]
                         :direction (if one-way "outbound" "both")}
                        note true (:partition-ms options) end))
               (recur (if one-way-decision (+ i 2) (inc i)) up))

             (= name "fault.pause.node")
             (let [[picked up] (up-pick up d)
                   goroutine (when (= "fault.pause.goroutine" (:name following)) following)
                   ticks-decision (get decisions (+ i 2))
                   ticks (when (= "fault.pause.ticks" (:name ticks-decision)) (:value ticks-decision))
                   note (take-note! :pause)
                   node (or (:node note) picked)
                   real (mapped-name nodes node)
                   _ (when (and note picked (not= picked (:node note)))
                       (swap! out update :disagree conj {:index (:index d) :tape picked :story (:node note)}))
                   ;; The story says the ticks as paused (d + 1), the tape the decision (d).
                   paused-ticks (or (:ticks note) (inc (or ticks 0)))
                   length (* (:tick-ms options) paused-ticks)]
               (if real
                 (step! d (str "node " node ": a goroutine paused for " paused-ticks " ticks")
                        {:kind "thread_pause" :node real :duration_ms length} note (or (some? note) (= (:options d) n)) length nil)
                 (skip! d "which node: the tape alone does not say: give the story"))
               (recur (+ i 1 (if goroutine 1 0) (if ticks 1 0)) up))

             (= name "fault.clock.node")
             (let [[picked up] (up-pick up d)
                   skew-decision (when (= "fault.clock.skew" (:name following)) following)
                   most (quot (dec (or (:options skew-decision) 1)) 2)
                   note (take-note! :skew)
                   skew (or (:skew note) (when skew-decision (- (:value skew-decision) most)) 0)
                   node (or (:node note) picked)
                   real (mapped-name nodes node)]
               (when (and note picked (not= picked (:node note)))
                 (swap! out update :disagree conj {:index (:index d) :tape picked :story (:node note)}))
               (cond
                 (zero? skew) (skip! d "a skew of 0 ticks")
                 real (step! d (str "node " node "'s clock skewed " skew " ticks")
                             {:kind "clock_skew" :node real :skip_ms (* (:tick-ms options) (abs skew)) :forward (pos? skew)}
                             note (or (some? note) (= (:options d) n)) (:clock-ms options) nil)
                 :else (skip! d "which node: the tape alone does not say: give the story"))
               (recur (if skew-decision (+ i 2) (inc i)) up))

             (= name "disk.sync.error")
             (if (= 1 (:value d))
               (let [note (take-note! :sync-error)
                     real (mapped-name nodes (:node note))]
                 (if real
                   (step! d (str "node " (:node note) ": sync of " (:file note) " failed")
                          {:kind "disk" :node real :failure "write_errors"} note true (:sync-error-ms options) nil)
                   (skip! d "which node synced is not on the tape (the node whose code ran): give the story"))
                 (recur (inc i) up))
               (do (swap! out update-in [:counted "disk.sync.error (no failure)"] (fnil inc 0))
                   (recur (inc i) up)))

             (= name "fault.crash_point")
             (if (= 1 (:value d))
               (let [power-decision (when (= "fault.crash_point.power" (:name following)) following)
                     note (take-note! :crash-point)
                     real (mapped-name nodes (:node note))]
                 (if real
                   (step! d (str "node " (:node note) (if (:power note) " lost power" " killed") " at " (:point note))
                          (if (:power note)
                            {:kind "durable_crash" :node real :one_in 1 :after_sync (str/starts-with? (str (:point note)) "after")}
                            {:kind "restart" :node real})
                          note true (:down-ms options)
                          (ending notes (:at note) (fn [x] (and (= :start (:kind x)) (= (:node note) (:node x))))))
                   (skip! d "which node's durability point is not on the tape: give the story"))
                 (recur (if power-decision (+ i 2) (inc i)) up))
               (do (swap! out update-in [:counted "fault.crash_point (no crash)"] (fnil inc 0))
                   (recur (inc i) up)))

             :else
             (do (skip! d (skip-reason name))
                 (recur (inc i) up)))))))))

;; Driving a plan on a session, a step at a time.

(defonce ^{:doc "The tape being driven: {:tape :plan :at (the next step) :results}, followed by
  the viz."} state (atom nil))

(defn load!
  "A tape's plan, ready to drive: `options` has :nodes (model node -> real node: a vector or a
  map), :story (a path; by default the tape's `.story.txt` when there is one) and the time
  conversions (`defaults`). -> the plan."
  [tape-path options]
  (let [tape (read-tape tape-path)
        story-path (or (:story options)
                       (let [guess (str/replace tape-path #"\.tape\.jsonl$" ".story.txt")]
                         (when (and (not= guess tape-path) (try (slurp guess) (catch #?(:jank jank.runtime.object_ref :default Exception) _ nil))) guess)))
        story (when story-path (read-story story-path))
        made (assoc (plan tape (:nodes options) story (dissoc options :nodes :story))
                    :tape tape-path :story story-path :decisions (count tape) :nodes (:nodes options))]
    (reset! state {:tape tape-path :plan made :at 0 :results []})
    (tap/tell :lean/plan made made)))

(defn next!
  "The plan's next step on the session: its fault (lab/fault!), then the timeline on for the
  step's wait (lab/advance!). -> {:step :fault (lab's result) :advance}"
  [session]
  (let [{:keys [plan at]} @state
        step (get (:steps plan) at)]
    (when-not step
      (throw (ex-info "determinismo: the tape has no step left" {:at at})))
    (swap! state assoc :running at)
    (try
      (let [fault (lab/fault! session (:inject step))
            advanced (lab/advance! session (:wait-ms step))
            result {:lean/step at :step step :fault (select-keys fault [:applied :refused])
                    :at-ns (:at-ns advanced)}]
        (swap! state (fn [s] (-> s (update :results conj result) (assoc :at (inc at)) (dissoc :running))))
        (tap/tell :lean/step result result))
      (catch #?(:jank jank.runtime.object_ref :default Exception) e
        (swap! state dissoc :running)
        (throw e)))))

(defn drive!
  "The plan's remaining steps on the session, one at a time. -> each step's result."
  [session]
  (loop [results []]
    (let [{:keys [plan at]} @state]
      (if (< at (count (:steps plan)))
        (recur (conj results (next! session)))
        results))))
