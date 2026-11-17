;; SPDX-License-Identifier: MIT
;; Elle as a service: POST a history (JSON lines, one operation each, in the order they happened)
;; to /check?model=list-append&consistency=strict-serializable, get Elle's verdict as JSON.
;;
;; An operation: {"process": 7, "type": "invoke", "f": "txn",
;;                "value": [["append", 3, 17], ["r", 4, null]]}
;; then its completion by the same process: "ok" (reads filled in), "fail" (it did not happen)
;; or "info" (unknown). Models: list-append ([append k v], [r k [v ...]]) and rw-register
;; ([w k v], [r k v]). An invocation never completed (its driver stopped mid-call) is closed as
;; info. closed-predicate (elle.closed-predicate, jepsen-io/mysql's closed-predicate test): first
;; an operation of f "init" whose value is [["init" k v] ...] (the universe's first state), then
;; transactions of [insert k v], [w k v], [delete k null], [r k v-or-null] and
;; [rp predicate rows] where a predicate is "true", ["=" a] or ["mod" a b] and rows are
;; [[k v] ...] (null in an invocation). The answer: {"valid": true | false | "unknown", "anomaly_types": [...], "not": [...],
;; "ops": n, "anomalies": "..."} (the anomalies as Elle prints them, cut short).
;;
;; Consistency: one of Elle's models, or strict-serializable-per-key: Elle's strict
;; serializability with real-time order only between operations touching a key in common, i.e.
;; serializable and each key linearizable (YDB's claim, its team's Jepsen suite's
;; ydb-serializable model). Its anomalies keep Elle's names (G-single-item-realtime: per key).
;;
;; &linearizable_keys=true (rw-register): Elle's :linearizable-keys?, each key's version order
;; inferred from real time, for a system that claims each key linearizable. Without it Elle
;; cannot order two blind writes of a key: two reads after both, answering one then the other,
;; pass; with it they are cyclic-versions.
(ns elle-service
  (:gen-class)
  (:require [clojure.data.json :as json]
            [clojure.string :as string]
            [clojure.walk :as walk]
            [bifurcan-clj.core :as bifurcan]
            [elle.closed-predicate :as closed-predicate]
            [elle.core :as elle]
            [elle.graph :as graph]
            [elle.list-append :as list-append]
            [elle.rels :as rels]
            [elle.rw-register :as rw-register]
            [jepsen.history :as history])
  (:import (com.sun.net.httpserver HttpExchange HttpHandler HttpServer)
           (io.lacuna.bifurcan ISet)
           (java.net InetSocketAddress URLDecoder)
           (java.nio.charset StandardCharsets)
           (java.util.concurrent Executors)
           (java.util.concurrent.locks ReentrantReadWriteLock)))

;; ELLE_PORT: another beside the host's (a test of the service itself).
(def port (Integer/parseInt (or (System/getenv "ELLE_PORT") "7700")))
;; What `/version` answers: the SDK (sdk/zig/elle.zig) replaces a running service that answers
;; another. 2: operations' times, and the window the anomalies formed in (window_ns). 3: reads
;; with a value twice reported here (duplicates). 4: strict-serializable-per-key. 5: linearizable_keys. A model added
;; (closed-predicate) leaves what programs send unchanged: the same version, the service rebuilt
;; and restarted by hand.
(def version "5")
;; The anomalies' text: each type's first examples, cut to `type-size-max`, then a count of the
;; rest, every type in turn; the whole cut to `anomalies-size-max` (what the SDK reports, as events
;; past the property's own cut). One cut of the whole map left a G1a out of two
;; timelines' text: their G-single-item-realtime examples filled 4,000 characters first (hunt run
;; 1468, 27 and 44).
(def anomalies-size-max 48000)
(def examples-per-type 3)
(def type-size-max 8000)
;; Histories checked at once (a run's timelines end together): a semaphore of this many, the
;; handlers themselves on a pool without bound, so `/version` always answers. Without an executor
;; the server ran every handler on its one thread, so a long check kept `/version` from answering
;; and the SDK replaced the service mid-check (run 200's timeline 151, srv3 2026-10-29); with a
;; pool of 4 for both, four long checks did the same in effect: every other check took the SDK's
;; start lock and waited there (a trial's three for 22 min behind a 40-worker hunt's, 2026-11-06).
(def threads 16)
(def checking (java.util.concurrent.Semaphore. threads true))

(defn- predicate
  "closed-predicate's predicate as Elle writes it: :true, [:= a] or [:mod a b]."
  [p]
  (if (= "true" p) :true (into [(keyword (first p))] (rest p))))

(defn- mop
  "A micro-operation as Elle reads it (closed-predicate's as its generator writes them)."
  [[f k v]]
  (case f
    "rp" [:rp (predicate k) (when v (into (sorted-map) (map vec) v))]
    "delete" [:delete k]
    [(keyword f) k v]))

(defn- operation [m]
  (let [f (keyword (get m "f"))
        mops (mapv mop (get m "value"))]
    {:process (get m "process")
     :type (keyword (get m "type"))
     :f f
     :time (get m "time" -1)
     ;; closed-predicate's universe: a map of keys to their first values.
     :value (if (= :init f) (into (sorted-map) (map (fn [[_ k v]] [k v])) mops) mops)}))

(defn- window
  "When the anomalies formed: the earliest and the latest time (the guest's clock, in
  nanoseconds) of the operations they name, or nil when they name none with a time."
  [anomalies]
  ;; Not in sorted maps: closed-predicate's predicate reads (numbers as keys, which a keyword
  ;; lookup cannot be compared with).
  (let [times (->> (tree-seq coll? seq anomalies)
                   (keep #(when (and (map? %) (not (sorted? %))) (:time %)))
                   (filter #(and (number? %) (>= % 0))))]
    (when (seq times) [(apply min times) (apply max times)])))

(defn- closed
  "The operations, with every invocation left open closed as :info (by process, in order)."
  [operations]
  (let [open (reduce (fn [open o]
                       (if (= :invoke (:type o))
                         (assoc open (:process o) o)
                         (dissoc open (:process o))))
                     (sorted-map) operations)]
    (into (vec operations) (map #(assoc % :type :info)) (vals open))))

(defn- shortened
  "Long lists of values (a read's) cut to their ends and a count: Elle prints an anomaly's reader
  first, and a read of hundreds of values left no room for the writer and the element."
  [x]
  (walk/postwalk (fn [v]
                   (if (and (vector? v) (> (count v) 8) (every? number? v))
                     (vec (concat (take 3 v)
                                  [(symbol (str "..." (- (count v) 6) "-more..."))]
                                  (take-last 3 v)))
                     v))
                 x))

(defn anomalies-text
  "`anomalies` (Elle's map of a type to its anomalies) as text: each type in turn, its first
  examples and how many more."
  [anomalies]
  ;; None (a valid history): `pr-str`'s text, as before this function, which the histories' host
  ;; checks recorded ("nil"): a timeline replayed after the change must judge the same (run 1482's
  ;; timeline 2 parted from its record on "" for "nil").
  (if (empty? anomalies)
    (pr-str anomalies)
    (let [text (->> anomalies
                    (map (fn [[kind found]]
                           (let [many (and (sequential? found) (> (count found) examples-per-type))
                                 shown (pr-str {kind (if many (vec (take examples-per-type found)) found)})]
                             (str (subs shown 0 (min type-size-max (count shown)))
                                  (when many
                                    (str " ;; " (- (count found) examples-per-type) " more "
                                         (name kind)))))))
                    (string/join "\n"))]
      (subs text 0 (min anomalies-size-max (count text))))))

(defn- duplicates
  "The list reads that hold a value twice. Appends are unique, so each is an anomaly; Elle crashed
  on them (a ClassCastException, run 176's timeline 27: a write answered with a
  conflict had taken effect, and its client appended again), so they are found here and Elle
  judges the reads with each value once."
  [operations]
  (vec (for [o operations
             :when (= :ok (:type o))
             [f k v] (:value o)
             :when (and (= :r f) (sequential? v) (not= (count v) (count (distinct v))))]
         {:op o :key k :values (vec (keep (fn [[x n]] (when (< 1 n) x)) (frequencies v)))})))

(defn- deduplicated [operations]
  (map (fn [o]
         (update o :value
                 (fn [mops]
                   (mapv (fn [[f k v :as mop]]
                           (if (and (= :r f) (sequential? v)) [f k (vec (distinct v))] mop))
                         mops))))
       operations))

(def per-key "strict-serializable-per-key")

(defn- keys-of [op]
  (into #{} (map second) (:value op)))

(defn- realtime-per-key-graph
  "elle.core/realtime-graph, between operations touching a key in common only: each key keeps
  the completed operations no later completion implies yet, and links them to the completion of
  every later invocation touching it (crashed and failed ones are never linked from, as Elle's)."
  [h]
  (history/ensure-pair-index h)
  (let [step (fn [[pending g] op]
               (case (:type op)
                 :invoke (if-let [done (history/completion h op)]
                           [pending (reduce #(graph/link-all-to %1 (get pending %2) done rels/realtime)
                                            g (keys-of op))]
                           [pending g])
                 :ok (let [^ISet implied (graph/in g op)
                           kept (fn [ops] (into #{op} (remove #(and implied (.contains implied %))) ops))]
                       [(reduce #(update %1 %2 kept) pending (keys-of op)) g])
                 [pending g]))
        [_ g] (reduce step [{} (bifurcan/linear (graph/op-digraph))] h)]
    {:graph (bifurcan/forked g)
     :explainer (elle/->RealtimeExplainer h)}))

;; Elle's realtime-graph is replaced JVM-wide while a per-key check runs: it runs alone (the
;; write lock), every other check beside the others (the read lock).
(def ^ReentrantReadWriteLock replacing (ReentrantReadWriteLock.))

(defn- under [lock f]
  (.lock lock)
  (try (f) (finally (.unlock lock))))

(defn- judged [checker consistency linearizable-keys h]
  (let [options (cond-> {} linearizable-keys (assoc :linearizable-keys? true))]
    (if (= per-key consistency)
      (under (.writeLock replacing)
             #(with-redefs [elle/realtime-graph realtime-per-key-graph]
                (checker (assoc options :consistency-models [:strict-serializable]) h)))
      (under (.readLock replacing)
             #(checker (assoc options :consistency-models [(keyword consistency)]) h)))))

(defn check [body model consistency linearizable-keys]
  (let [operations (->> (string/split-lines body)
                        (remove string/blank?)
                        (map json/read-str)
                        (map operation)
                        closed)
        twice (when (= model "list-append") (duplicates operations))
        checker (case model
                  "list-append" list-append/check
                  "rw-register" rw-register/check
                  "closed-predicate" closed-predicate/check)
        result (judged checker consistency linearizable-keys
                       (history/history (if (seq twice) (deduplicated operations) operations)))
        result (if (seq twice)
                 (-> result
                     (assoc :valid? false)
                     (update :anomaly-types #(distinct (conj (vec %) :duplicate-elements)))
                     (assoc-in [:anomalies :duplicate-elements] twice))
                 result)
        valid (:valid? result)
        formed (window (:anomalies result))
        anomalies (anomalies-text (shortened (:anomalies result)))]
    {:valid (if (keyword? valid) (name valid) valid)
     :anomaly_types (map name (:anomaly-types result))
     :not (map name (:not result))
     :ops (count operations)
     :window_ns formed
     :anomalies anomalies}))

(defn- parameters [^HttpExchange exchange]
  (into {}
        (for [pair (string/split (or (.getRawQuery (.getRequestURI exchange)) "") #"&")
              :let [[k v] (string/split pair #"=" 2)]
              :when (seq k)]
          [k (URLDecoder/decode (or v "") StandardCharsets/UTF_8)])))

(defn- respond [^HttpExchange exchange status value]
  (let [bytes (.getBytes ^String (json/write-str value) StandardCharsets/UTF_8)]
    (.add (.getResponseHeaders exchange) "Content-Type" "application/json")
    (.sendResponseHeaders exchange status (alength bytes))
    (with-open [out (.getResponseBody exchange)]
      (.write out bytes))))

(defn- handle [^HttpExchange exchange]
  (try
    (let [body (slurp (.getRequestBody exchange) :encoding "UTF-8")
          {:strs [model consistency linearizable_keys]
           :or {model "list-append" consistency "strict-serializable"}} (parameters exchange)]
      (.acquire checking)
      (let [answer (try (check body model consistency (= "true" linearizable_keys))
                        (finally (.release checking)))]
        (respond exchange 200 answer)))
    (catch Throwable t
      (respond exchange 500 {:error (str t)}))
    (finally
      (.close exchange))))

(defn -main [& _]
  (let [server (HttpServer/create (InetSocketAddress. port) 16)]
    (.createContext server "/check" (reify HttpHandler (handle [_ exchange] (handle exchange))))
    (.createContext server "/version" (reify HttpHandler
                                        (handle [_ exchange]
                                          (try (respond exchange 200 {:version version})
                                               (finally (.close exchange))))))
    (.setExecutor server (Executors/newCachedThreadPool))
    (.start server)
    (println "elle-service on port" port)))
