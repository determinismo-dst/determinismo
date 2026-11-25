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
