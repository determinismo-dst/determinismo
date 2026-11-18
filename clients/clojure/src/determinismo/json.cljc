;; SPDX-License-Identifier: MIT
;; JSON for determinismo's answers, in plain Clojure: the same code on the JVM, babashka and jank
;; (no library on any of them). Objects read as maps with keyword keys, arrays as vectors.
(ns determinismo.json
  (:require [clojure.string :as str]))

;; Under jank, the same results through its native reader and printer: JSON text rewritten as EDN
;; (keys left strings, keywords made after reading as below, commas and colons spaces, null nil, a
;; string's \/ as /) for read-string, and pr-str's EDN rewritten as JSON. A strategy host's call
;; took 90 us in plain Clojure under jank (72 of them reading), 32 this way (2026-11-18).
#?(:jank
   (cpp/raw "
#include <cctype>
#include <cstring>
#include <string>
#include <utility>
#include <vector>
std::string determinismo_json_to_edn(std::string const &in) {
  std::string out;
  out.reserve(in.size() + 16);
  size_t i = 0, n = in.size();
  while (i < n) {
    char c = in[i];
    if (c == '\"') {
      out.push_back('\"');
      i++;
      while (i < n && in[i] != '\"') {
        if (in[i] == '\\\\' && i + 1 < n) {
          if (in[i + 1] == '/') out.push_back('/');
          else { out.push_back('\\\\'); out.push_back(in[i + 1]); }
          i += 2;
          continue;
        }
        out.push_back(in[i]);
        i++;
      }
      out.push_back('\"');
      i++;
    } else if (c == ',' || c == ':') {
      out.push_back(' ');
      i++;
    } else if (c == 'n' && in.compare(i, 4, \"null\") == 0) {
      out += \"nil\";
      i += 4;
    } else {
      out.push_back(c);
      i++;
    }
  }
  return out;
}
// pr-str's EDN as JSON (write-json's results): keywords their names, nil null, a map's entries
// \"k\":v, vectors, lists and sets arrays, a bigint's N or a decimal's M left off, strings as
// pr-str quoted them, anything else (a symbol, a character) a string of its text.
std::string determinismo_edn_to_json(std::string const &in) {
  std::string out;
  out.reserve(in.size() + 16);
  std::vector<std::pair<char, size_t>> open; // 'm' a map, 'a' an array: items so far.
  auto item = [&]() {
    if (open.empty()) return;
    auto &top = open.back();
    if (top.second > 0) out.push_back(top.first == 'm' && top.second % 2 == 1 ? ':' : ',');
    top.second++;
  };
  auto quoted = [&](std::string const &text) {
    out.push_back('\"');
    for (char c : text) {
      if (c == '\"' || c == '\\\\') out.push_back('\\\\');
      out.push_back(c);
    }
    out.push_back('\"');
  };
  size_t i = 0, n = in.size();
  while (i < n) {
    char c = in[i];
    if (c == ' ' || c == ',' || c == '\\n' || c == '\\t' || c == '\\r') { i++; continue; }
    if (c == '{') { item(); out.push_back('{'); open.push_back({'m', 0}); i++; continue; }
    if (c == '[' || c == '(') { item(); out.push_back('['); open.push_back({'a', 0}); i++; continue; }
    if (c == '#' && i + 1 < n && in[i + 1] == '{') { item(); out.push_back('['); open.push_back({'a', 0}); i += 2; continue; }
    if (c == '}' || c == ']' || c == ')') {
      out.push_back(!open.empty() && open.back().first == 'm' ? '}' : ']');
      if (!open.empty()) open.pop_back();
      i++;
      continue;
    }
    item();
    if (c == '\"') {
      size_t start = i++;
      while (i < n && in[i] != '\"') i += in[i] == '\\\\' ? 2 : 1;
      i++;
      out.append(in, start, i - start);
      continue;
    }
    size_t start = i;
    while (i < n && !std::strchr(\" ,\\n\\t\\r{}[]()\\\"\", in[i])) i++;
    std::string token = in.substr(start, i - start);
    bool number = std::isdigit((unsigned char)token[0]) ||
                  ((token[0] == '-' || token[0] == '+') && token.size() > 1 && std::isdigit((unsigned char)token[1]));
    if (token == \"nil\") out += \"null\";
    else if (token == \"true\" || token == \"false\") out += token;
    else if (token[0] == ':') quoted(token.substr(token.find_last_of('/') == std::string::npos ? 1 : token.find_last_of('/') + 1));
    else if (number) {
      if (token.back() == 'N' || token.back() == 'M') token.pop_back();
      out += token;
    } else if (token[0] == '\\\\' && token.size() == 2) quoted(token.substr(1));
    else quoted(token);
  }
  return out;
}
"))

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

#?(:jank
   (defn- keywordize
     "Every map's keys as keywords, as read-value makes them."
     [x]
     (cond (map? x) (persistent! (reduce-kv (fn [m k v] (assoc! m (keyword k) (keywordize v))) (transient {}) x))
           (vector? x) (mapv keywordize x)
           :else x)))

(defn read-json
  "The JSON value in `text`."
  [text]
  #?(:jank (keywordize (read-string (str (cpp/determinismo_json_to_edn (cpp/cast cpp/std.string text)))))
     :default (first (read-value text 0))))

(defn- write-string [s]
  (str "\""
       (-> s
           (str/replace "\\" "\\\\")
           (str/replace "\"" "\\\"")
           (str/replace "\n" "\\n")
           (str/replace "\t" "\\t")
           (str/replace "\r" "\\r"))
       "\""))

(defn- write-value
  [value]
  (cond
    (nil? value) "null"
    (true? value) "true"
    (false? value) "false"
    (number? value) (str value)
    (keyword? value) (write-string (name value))
    (string? value) (write-string value)
    (map? value) (str "{" (str/join "," (map (fn [[k v]] (str (write-string (name k)) ":" (write-value v))) value)) "}")
    (sequential? value) (str "[" (str/join "," (map write-value value)) "]")
    :else (write-string (str value))))

(defn write-json
  "`value` (maps, sequences, strings, keywords, numbers, booleans, nil) as JSON."
  [value]
  #?(:jank (str (cpp/determinismo_edn_to_json (cpp/cast cpp/std.string (pr-str value))))
     :default (write-value value)))
