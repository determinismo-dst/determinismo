;; SPDX-License-Identifier: MIT
;; The service's own tests, through `check` as a POST reaches it: `clojure -M:test` in
;; checkers/elle (a JVM with Elle's dependencies; infra/host/unit.sh runs the Zig tests only).
(ns elle-service-test
  (:require [clojure.data.json :as json]
            [clojure.string :as string]
            [clojure.test :refer [deftest is testing]]
            [elle-service :as service]))

(defn- history [& operations]
  (string/join "\n" (map json/write-str operations)))

(defn- txn [process type & mops]
  {"process" process "type" type "f" "txn" "value" (vec mops)})

(def ^:private init
  [{"process" 0 "type" "invoke" "f" "init" "value" [["init" 0 0] ["init" 1 0]]}
   {"process" 0 "type" "ok" "f" "init" "value" [["init" 0 0] ["init" 1 0]]}])

;; closed-predicate, a read skew through a plain write: T1 overwrites key 1, T2 reads T1's
;; value of key 1 and key 0 as never written. init -ww-> T1 -wr-> T2 -rw-> init. Elle 0.2.8's
;; ww-graph matched writes as `:write`, never `:w`: no ww edge, no cycle, valid
;; (src/elle/closed_predicate.clj).
(def ^:private read-skew
  (apply history (concat init [(txn 1 "invoke" ["w" 1 1]) (txn 1 "ok" ["w" 1 1])
                               (txn 2 "invoke" ["r" 1 nil] ["r" 0 nil])
                               (txn 2 "ok" ["r" 1 1] ["r" 0 nil])])))

;; The same transactions, T2 reading what the init wrote to key 0: serializable.
(def ^:private consistent-read
  (apply history (concat init [(txn 1 "invoke" ["w" 1 1]) (txn 1 "ok" ["w" 1 1])
                               (txn 2 "invoke" ["r" 1 nil] ["r" 0 nil])
                               (txn 2 "ok" ["r" 1 1] ["r" 0 0])])))

(deftest closed-predicate-writes-have-write-write-edges
  (doseq [consistency ["serializable" "snapshot-isolation"]]
    (testing consistency
      (let [answer (service/check read-skew "closed-predicate" consistency false)]
        (is (false? (:valid answer)) (pr-str answer))))))

(deftest closed-predicate-consistent-reads-pass
  (let [answer (service/check consistent-read "closed-predicate" "serializable" false)]
    (is (true? (:valid answer)) (pr-str answer))))

;; Fixes from a Lean replica of Elle's round 2 (each history its minimal one).

(defn- op [process type f mops] {"process" process "type" type "f" f "value" mops})

(defn- answer [model consistency & ops]
  (service/check (apply history ops) model consistency false))

;; D10: closed-predicate's versions-after dropped its unborn branch: snapshot isolation passed a
;; G-single through a predicate read missing key 1, which the init created and T1 deleted.
(deftest closed-predicate-predicate-read-of-an-init-key
  (let [a (answer "closed-predicate" "snapshot-isolation"
                  (op 0 "invoke" "init" [["init" 0 0] ["init" 1 0]])
                  (op 0 "ok" "init" [["init" 0 0] ["init" 1 0]])
                  (op 1 "invoke" "txn" [["delete" 1 nil]]) (op 1 "ok" "txn" [["delete" 1 nil]])
                  (op 2 "invoke" "txn" [["rp" ["=" 0] nil] ["r" 1 nil]])
                  (op 2 "ok" "txn" [["rp" ["=" 0] []] ["r" 1 nil]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D3: the process order skipped :info operations: process 0 read its own later (indeterminate)
;; append, and strong session read committed passed it.
(deftest process-order-reaches-info-operations
  (let [a (answer "list-append" "strong-session-read-committed"
                  (op 0 "invoke" "txn" [["r" 0 nil]]) (op 0 "ok" "txn" [["r" 0 [1]]])
                  (op 0 "invoke" "txn" [["append" 0 1]]) (op 0 "info" "txn" [["append" 0 1]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D3's other side (D5): with the :info append aborted, the read [2 1] is an aborted read, which
;; read uncommitted allows; real time into the :info completion made it fail.
(deftest read-uncommitted-allows-an-aborted-info-read
  (let [a (answer "list-append" "strong-read-uncommitted"
                  (op 0 "invoke" "txn" [["append" 0 1]]) (op 0 "ok" "txn" [["append" 0 1]])
                  (op 0 "invoke" "txn" [["append" 0 2]]) (op 0 "info" "txn" [["append" 0 2]])
                  (op 1 "invoke" "txn" [["r" 0 nil]]) (op 1 "ok" "txn" [["r" 0 [2 1]]]))]
    (is (true? (:valid a)) (pr-str a))))

;; D13: rw-register didn't index :info writes: process 0 read its own later indeterminate write,
;; and strict serializability passed it.
(deftest rw-register-indexes-info-writes
  (let [a (answer "rw-register" "strict-serializable"
                  (op 0 "invoke" "txn" [["r" 0 nil]]) (op 0 "ok" "txn" [["r" 0 1]])
                  (op 0 "invoke" "txn" [["w" 0 1]]) (op 0 "info" "txn" [["w" 0 1]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D16: after duplicates, `not` was the deduplicated history's boundary ([] when Elle found it
;; valid); duplicate elements rule out read uncommitted.
(deftest duplicates-name-what-they-rule-out
  (let [a (answer "list-append" "serializable"
                  (op 0 "invoke" "txn" [["r" 0 nil]]) (op 0 "ok" "txn" [["r" 0 []]])
                  (op 1 "invoke" "txn" [["append" 1 1] ["r" 1 nil]])
                  (op 1 "ok" "txn" [["append" 1 1] ["r" 1 [1 1]]]))]
    (is (false? (:valid a)) (pr-str a))
    (is (= ["read-uncommitted"] (vec (:not a))) (pr-str a))))

;; D17: deduplicated in place, the read [1 1 2] became [1 2] and tied with [2 1]; Elle's hash
;; order then hid the G0-realtime it finds without the duplicated read.
(deftest duplicates-hide-no-other-anomaly
  (let [a (answer "list-append" "strict-serializable"
                  (op 2 "invoke" "txn" [["append" 1 1] ["r" 1 nil]])
                  (op 2 "ok" "txn" [["append" 1 1] ["r" 1 [2 1]]])
                  (op 1 "invoke" "txn" [["append" 0 1] ["append" 0 2]])
                  (op 0 "invoke" "txn" [["append" 1 2] ["r" 1 nil]])
                  (op 0 "ok" "txn" [["append" 1 2] ["r" 1 [1 1 2]]])
                  (op 1 "ok" "txn" [["append" 0 1] ["append" 0 2]])
                  (op 1 "invoke" "txn" [["r" 0 nil]]) (op 1 "ok" "txn" [["r" 0 []]]))]
    (is (some #{"G0-realtime"} (:anomaly_types a)) (pr-str a))
    (is (some #{"duplicate-elements"} (:anomaly_types a)) (pr-str a))))

;; D19: per key, a predicate read's "key" was its predicate, so real time never ordered it after
;; T1's write; Elle's strict serializability finds the stale predicate read (G-single-realtime).
(deftest per-key-predicate-reads-read-every-key
  (let [a (answer "closed-predicate" "strict-serializable-per-key"
                  (op 0 "invoke" "init" [["init" 0 0] ["init" 1 0]])
                  (op 0 "ok" "init" [["init" 0 0] ["init" 1 0]])
                  (op 1 "invoke" "txn" [["w" 0 1]]) (op 1 "ok" "txn" [["w" 0 1]])
                  (op 2 "invoke" "txn" [["rp" ["=" 0] nil]])
                  (op 2 "ok" "txn" [["rp" ["=" 0] [[0 0] [1 0]]]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D23 (round 3 of the Lean replica): D3's fix took real time out of :info completions for models
;; allowing G1a, and lost this strong read uncommitted violation: the :info transaction can't have
;; committed ([3 4] and [2] aren't on one trace), so 2 precedes 1 (T1 -ww-> T0), with real time
;; T0 -> T1. Elle 0.2.8 caught it through the :info operation; D5's fix catches it without.
(deftest strong-read-uncommitted-without-the-info-edge
  (let [a (answer "list-append" "strong-read-uncommitted"
                  (op 0 "invoke" "txn" [["r" 0 nil] ["append" 0 1]]) (op 0 "ok" "txn" [["r" 0 [2]] ["append" 0 1]])
                  (op 0 "invoke" "txn" [["r" 0 nil] ["append" 0 2]]) (op 0 "ok" "txn" [["r" 0 [3 4]] ["append" 0 2]])
                  (op 0 "invoke" "txn" [["append" 0 3] ["append" 0 4]]) (op 0 "info" "txn" [["append" 0 3] ["append" 0 4]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D1: an append nobody read became an anti-dependency: snapshot isolation passed a G-single
;; present in every interpretation (both orders of key 1's appends).
(deftest snapshot-isolation-sees-g-single-through-unread-appends
  (let [a (answer "list-append" "snapshot-isolation"
                  (op 0 "invoke" "txn" [["r" 0 nil] ["append" 1 1]])
                  (op 1 "invoke" "txn" [["r" 1 nil] ["append" 1 2] ["append" 0 1]])
                  (op 0 "ok" "txn" [["r" 0 []] ["append" 1 1]])
                  (op 1 "ok" "txn" [["r" 1 []] ["append" 1 2] ["append" 0 1]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D7: rw-register dropped the self-edge of a transaction reading its own later write.
(deftest rw-register-future-read
  (let [a (answer "rw-register" "strict-serializable"
                  (op 0 "invoke" "txn" [["r" 0 nil] ["w" 0 1]]) (op 0 "ok" "txn" [["r" 0 1] ["w" 0 1]]))]
    (is (false? (:valid a)) (pr-str a))))

;; D8: list-append threw on a garbage read (an element nobody appended) instead of reporting it.
(deftest list-append-garbage-read
  (let [a (try (answer "list-append" "strict-serializable"
                       (op 0 "invoke" "txn" [["r" 0 nil]]) (op 0 "ok" "txn" [["r" 0 [7]]]))
               (catch Throwable e {:threw (str (class e) ": " (.getMessage e))}))]
    (is (false? (:valid a)) (pr-str a))))


;; D12 (round 4 of the Lean replica's refinement): among reads of equal length, list-append's
;; version order followed Clojure's hash-set order, so two histories that differ only in key 0's
;; values 1 and 2 swapped got different verdicts (Elle 0.2.8: invalid, G0, and valid). Ordered by
;; elements no failed operation appended, then where each was first read, a renaming changes none.
(deftest list-append-verdict-survives-renaming-values
  (let [pair (fn [x y] (answer "list-append" "read-uncommitted"
                               (op 0 "invoke" "txn" [["append" 0 x] ["append" 1 4]]) (op 0 "ok" "txn" [["append" 0 x] ["append" 1 4]])
                               (op 1 "invoke" "txn" [["append" 0 y] ["append" 1 3]]) (op 1 "ok" "txn" [["append" 0 y] ["append" 1 3]])
                               (op 2 "invoke" "txn" [["r" 0 nil]]) (op 2 "ok" "txn" [["r" 0 [x]]])
                               (op 3 "invoke" "txn" [["r" 0 nil]]) (op 3 "ok" "txn" [["r" 0 [y]]])
                               (op 4 "invoke" "txn" [["r" 1 nil]]) (op 4 "ok" "txn" [["r" 1 [3 4]]])))
        a (pair 1 2)
        b (pair 2 1)]
    (is (= (:valid a) (:valid b)) (pr-str [a b]))))
