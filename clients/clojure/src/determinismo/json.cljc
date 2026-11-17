;; SPDX-License-Identifier: MIT
;; JSON for determinismo's answers, in plain Clojure: the same code on the JVM, babashka and jank
;; (no library on any of them). Objects read as maps with keyword keys, arrays as vectors.
(ns determinismo.json
  (:require [clojure.string :as str]))

(declare read-value)

(defn- parse-long-hex [text]
  (reduce (fn [n c] (+ (* n 16) (str/index-of "0123456789abcdef" (str/lower-case (str c))))) 0 text))


(defn- skip-space [text i]
  (loop [i i]
    (if (and (< i (count text)) (str/includes? " \t\n\r" (str (nth text i))))
      (recur (inc i))
      i)))

(defn- read-string-at
  "The JSON string starting at `i` (its opening quote): [value next-index]."
  [text i]
  (loop [i (inc i) out []]
    (let [c (nth text i)]
      (cond
        (= c \") [(apply str out) (inc i)]
        (= c \\) (let [e (nth text (inc i))]
                   (case e
                     \n (recur (+ i 2) (conj out "\n"))
                     \t (recur (+ i 2) (conj out "\t"))
                     \r (recur (+ i 2) (conj out "\r"))
                     \b (recur (+ i 2) (conj out "\b"))
                     \f (recur (+ i 2) (conj out "\f"))
                     \u (recur (+ i 6) (conj out (str (char (parse-long-hex (subs text (+ i 2) (+ i 6)))))))
                     (recur (+ i 2) (conj out (str e)))))
        :else (recur (inc i) (conj out (str c)))))))

(defn- integer-of
  "A JSON integer, exact: a seed or a hash past 2^63 too, as a bigint (parse-long, as Clojure's
  everywhere, answers nil past a long)."
  [token]
  (or (parse-long token) (bigint token)))

(defn- read-number-at [text i]
  (let [end (loop [j i]
              (if (and (< j (count text)) (str/includes? "+-0123456789.eE" (str (nth text j))))
                (recur (inc j))
                j))
        token (subs text i end)]
    [(if (some #(str/includes? token %) ["." "e" "E"]) (parse-double token) (integer-of token)) end]))

(defn- read-value [text i]
  (let [i (skip-space text i)
        c (nth text i)]
    (cond
      (= c \{) (loop [i (skip-space text (inc i)) m {}]
                 (if (= (nth text i) \})
                   [m (inc i)]
                   (let [[k i] (read-string-at text i)
                         i (inc (skip-space text i)) ; past the colon
                         [v i] (read-value text i)
                         i (skip-space text i)
                         m (assoc m (keyword k) v)]
                     (if (= (nth text i) \,)
                       (recur (skip-space text (inc i)) m)
                       [m (inc i)]))))
      (= c \[) (loop [i (skip-space text (inc i)) v []]
                 (if (= (nth text i) \])
                   [v (inc i)]
                   (let [[x i] (read-value text i)
                         i (skip-space text i)]
                     (if (= (nth text i) \,)
                       (recur (skip-space text (inc i)) (conj v x))
                       [(conj v x) (inc i)]))))
      (= c \") (read-string-at text i)
      (str/starts-with? (subs text i) "true") [true (+ i 4)]
      (str/starts-with? (subs text i) "false") [false (+ i 5)]
      (str/starts-with? (subs text i) "null") [nil (+ i 4)]
      :else (read-number-at text i))))

(defn read-json
  "The JSON value in `text`."
  [text]
  (first (read-value text 0)))

(defn- write-string [s]
  (str "\""
       (-> s
           (str/replace "\\" "\\\\")
           (str/replace "\"" "\\\"")
           (str/replace "\n" "\\n")
           (str/replace "\t" "\\t")
           (str/replace "\r" "\\r"))
       "\""))

(defn write-json
  "`value` (maps, sequences, strings, keywords, numbers, booleans, nil) as JSON."
  [value]
  (cond
    (nil? value) "null"
    (true? value) "true"
    (false? value) "false"
    (number? value) (str value)
    (keyword? value) (write-string (name value))
    (string? value) (write-string value)
    (map? value) (str "{" (str/join "," (map (fn [[k v]] (str (write-string (name k)) ":" (write-json v))) value)) "}")
    (sequential? value) (str "[" (str/join "," (map write-json value)) "]")
    :else (write-string (str value))))
