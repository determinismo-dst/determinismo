;; SPDX-License-Identifier: MIT
(ns determinismo.json
  "JSON for determinismo.ffi and determinismo.workload, with nothing but Clojure: definitions,
  details and records go out as JSON (keywords and symbols as strings, other collections as
  arrays, a key's dashes kept unless `snake` asks for underscores), the system, records and
  bindings come in as Clojure data (object keys as keywords)."
  (:require [clojure.string :as string]))

(set! *warn-on-reflection* true)

(defn- string-write [^StringBuilder out ^String text]
  (.append out \")
  (dotimes [i (.length text)]
    (let [c (.charAt text i)]
      (case c
        \" (.append out "\\\"")
        \\ (.append out "\\\\")
        \newline (.append out "\\n")
        \return (.append out "\\r")
        \tab (.append out "\\t")
        (if (< (int c) 0x20)
          (.append out (format "\\u%04x" (int c)))
          (.append out c)))))
  (.append out \"))

(defn- key-text [k snake]
  (let [text (if (or (keyword? k) (symbol? k)) (name k) (str k))]
    (if snake (string/replace text "-" "_") text)))

(defn- value-write [^StringBuilder out value snake]
  (cond
    (nil? value) (.append out "null")
    (string? value) (string-write out value)
    (boolean? value) (.append out (if value "true" "false"))
    (or (keyword? value) (symbol? value)) (string-write out (name value))
    (integer? value) (.append out (str value))
    (number? value) (let [d (double value)]
                      (if (or (Double/isNaN d) (Double/isInfinite d))
                        (.append out "null")
                        (.append out (str d))))
    (map? value) (do (.append out \{)
                     (loop [entries (seq value) first? true]
                       (when-let [[k v] (first entries)]
                         (when-not first? (.append out \,))
                         (string-write out (key-text k snake))
                         (.append out \:)
                         (value-write out v snake)
                         (recur (next entries) false)))
                     (.append out \}))
    (or (sequential? value) (set? value) (.isArray (class value)))
    (do (.append out \[)
        (loop [items (seq value) first? true]
          (when-let [s items]
            (when-not first? (.append out \,))
            (value-write out (first s) snake)
            (recur (next s) false)))
        (.append out \]))
    :else (string-write out (str value))))

(defn write-str
  "Clojure data as JSON text; with `snake`, keys' dashes as underscores (Zig's field names)."
  (^String [value] (write-str value false))
  (^String [value snake]
   (let [out (StringBuilder.)]
     (value-write out value snake)
     (str out))))

;; Reading ---------------------------------------------------------------------------------

(defn- fail [^String text at what]
  (throw (ex-info (str "JSON: " what " at " at) {:text (subs text 0 (min 200 (.length text))) :at at})))

(defn- skip ^long [^String text ^long at]
  (loop [at at]
    (if (and (< at (.length text)) (Character/isWhitespace (.charAt text at))) (recur (inc at)) at)))

(declare ^:private value-read)

(defn- string-read [^String text ^long at]
  (let [out (StringBuilder.)]
    (loop [at (inc at)]
      (when (>= at (.length text)) (fail text at "an unterminated string"))
      (let [c (.charAt text at)]
        (cond
          (= c \") [(str out) (inc at)]
          (= c \\) (let [e (.charAt text (inc at))]
                     (case e
                       \u (do (.append out (char (Integer/parseInt (subs text (+ at 2) (+ at 6)) 16)))
                              (recur (+ at 6)))
                       (do (.append out (case e \n \newline \r \return \t \tab \b \backspace \f \formfeed e))
                           (recur (+ at 2)))))
          :else (do (.append out c) (recur (inc at))))))))

(defn- bigint-or-long [^String token]
  (try (Long/parseLong token) (catch NumberFormatException _ (bigint token))))

(defn- number-read [^String text ^long at]
  (let [end (loop [end at]
              (if (and (< end (.length text)) (contains? #{\- \+ \. \e \E \0 \1 \2 \3 \4 \5 \6 \7 \8 \9} (.charAt text end)))
                (recur (inc end))
                end))
        token (subs text at end)]
    [(if (some #{\. \e \E} token) (Double/parseDouble token) (bigint-or-long token)) end]))

(defn- value-read [^String text ^long at]
  (let [at (skip text at)]
    (when (>= at (.length text)) (fail text at "the end"))
    (case (.charAt text at)
      \{ (loop [at (skip text (inc at)) result (transient {})]
           (if (= \} (.charAt text at))
             [(persistent! result) (inc at)]
             (let [[k at] (string-read text (skip text at))
                   at (skip text at)
                   _ (when-not (= \: (.charAt text at)) (fail text at "no colon"))
                   [v at] (value-read text (inc at))
                   at (skip text at)
                   result (assoc! result (keyword k) v)]
               (case (.charAt text at)
                 \, (recur (skip text (inc at)) result)
                 \} [(persistent! result) (inc at)]
                 (fail text at "no comma")))))
      \[ (loop [at (skip text (inc at)) result (transient [])]
           (if (= \] (.charAt text at))
             [(persistent! result) (inc at)]
             (let [[v at] (value-read text at)
                   at (skip text at)
                   result (conj! result v)]
               (case (.charAt text at)
                 \, (recur (skip text (inc at)) result)
                 \] [(persistent! result) (inc at)]
                 (fail text at "no comma")))))
      \" (string-read text at)
      \t (if (.startsWith text "true" at) [true (+ at 4)] (fail text at "a word"))
      \f (if (.startsWith text "false" at) [false (+ at 5)] (fail text at "a word"))
      \n (if (.startsWith text "null" at) [nil (+ at 4)] (fail text at "a word"))
      (number-read text at))))

(defn read-str
  "JSON text as Clojure data, object keys as keywords."
  [^String text]
  (let [[value at] (value-read text 0)]
    (when (< (skip text at) (.length text)) (fail text at "more after the value"))
    value))
