;; SPDX-License-Identifier: MIT
(ns determinismo.ffi
  "libdeterminismo (the Zig SDK behind a C ABI, sdk/zig/ffi.zig) from Clojure, through Java's
  FFM (java.lang.foreign: Java 22 or later, run with --enable-native-access=ALL-UNNAMED).

  Its functions are made as this namespace loads, from libdeterminismo.json: the library's
  interface, which the build writes from the table the library is checked against
  (sdk/zig/bindings.zig). Nothing here names a function: one added there is here on the next
  load. Each is a Clojure function named without its det_ prefix, dashes for underscores
  (det_random_below is `random-below`), taking its parameters in order:

    string   a string
    json     JSON text, or Clojure data written as JSON (determinismo.json)
    buffer   the capacity to give it: the function returns the bytes it wrote (called again
             with room enough when it had more)
    u64 i32 f64 bool   numbers and booleans

  An i32 result below 0 throws, with the error's name from the interface.

  The library is DETERMINISMO_LIBRARY (determinismo sets it for programs it runs on the host),
  else the guest's /opt/determinismo/lib/libdeterminismo.so (in the runner and every node); its
  interface beside it, with .json for .so."
  (:require [clojure.string :as string]
            [determinismo.json :as json])
  (:import (java.lang.foreign Arena FunctionDescriptor Linker Linker$Option MemoryLayout
                              MemorySegment SymbolLookup ValueLayout)
           (java.lang.invoke MethodHandle)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files Path)))

(set! *warn-on-reflection* true)

(def library-path
  (or (System/getenv "DETERMINISMO_LIBRARY") "/opt/determinismo/lib/libdeterminismo.so"))

(def interface
  "libdeterminismo.json, as data."
  (-> (Path/of (string/replace library-path #"\.so$" ".json") (make-array String 0))
      Files/readString
      json/read-str))

(def ^:private lookup
  (delay (SymbolLookup/libraryLookup (Path/of ^String library-path (make-array String 0)) (Arena/global))))

(def ^:private error-names
  (into {} (map (juxt :code :name)) (:errors interface)))

(defn- layouts [type]
  (case type
    ("string" "json" "buffer") [ValueLayout/ADDRESS ValueLayout/JAVA_LONG]
    "u64" [ValueLayout/JAVA_LONG]
    "i32" [ValueLayout/JAVA_INT]
    "f64" [ValueLayout/JAVA_DOUBLE]
    "bool" [ValueLayout/JAVA_BOOLEAN]))

(defn- handle ^MethodHandle [{:keys [name params returns]}]
  (let [arguments (into-array MemoryLayout (mapcat (comp layouts :type) params))
        descriptor (if returns
                     (FunctionDescriptor/of (first (layouts returns)) arguments)
                     (FunctionDescriptor/ofVoid arguments))
        symbol (.orElseThrow (.find ^SymbolLookup @lookup ^String name))]
    (.downcallHandle (Linker/nativeLinker) ^MemorySegment symbol ^FunctionDescriptor descriptor
                     ^"[Ljava.lang.foreign.Linker$Option;" (make-array Linker$Option 0))))

(defn- bytes-segment [^Arena arena ^bytes data]
  (if (zero? (alength data))
    MemorySegment/NULL
    (let [segment (.allocate arena (long (alength data)))]
      (MemorySegment/copy data (int 0) segment ValueLayout/JAVA_BYTE (long 0) (alength data))
      segment)))

(defn- arguments
  "The C arguments for a call's parameters: [arguments buffers], each buffer its segment."
  [^Arena arena params values]
  (reduce (fn [[out buffers] [{:keys [type]} value]]
            (case type
              "string" (let [data (.getBytes (str value) StandardCharsets/UTF_8)]
                         [(conj out (bytes-segment arena data) (long (alength data))) buffers])
              "json" (let [text (if (string? value) value (json/write-str value))
                           data (.getBytes ^String text StandardCharsets/UTF_8)]
                       [(conj out (bytes-segment arena data) (long (alength data))) buffers])
              "buffer" (let [capacity (long value)
                             segment (.allocate arena (max 1 capacity))]
                         [(conj out segment capacity) (conj buffers [segment capacity])])
              "u64" [(conj out (long value)) buffers]
              "i32" [(conj out (int value)) buffers]
              "f64" [(conj out (double value)) buffers]
              "bool" [(conj out (boolean value)) buffers]))
          [[] []]
          (map vector params values)))

(defn- call [^MethodHandle method {:keys [name params returns] :as function} values]
  (when-not (= (count params) (count values))
    (throw (ex-info (str name " takes " (count params) " arguments") {:function name :given (count values)})))
  (with-open [arena (Arena/ofConfined)]
    (let [[out buffers] (arguments arena params values)
          result (.invokeWithArguments method ^java.util.List out)]
      (if-let [[^MemorySegment segment capacity] (first buffers)]
        (let [size (long result)]
          (if (> size (long capacity))
            (call method function (assoc (vec values) (.indexOf ^java.util.List (mapv :type params) "buffer") size))
            (.toArray (.asSlice segment 0 size) ValueLayout/JAVA_BYTE)))
        (if (and (= returns "i32") (neg? (int result)))
          (throw (ex-info (str name ": " (get error-names (int result) "error"))
                          {:function name :code (int result) :error (get error-names (int result))}))
          result)))))

(defn- clojure-name [c-name]
  (symbol (string/replace (string/replace-first c-name #"^det_" "") "_" "-")))

(doseq [{:keys [name params doc] :as function} (:functions interface)]
  (let [method (delay (handle function))
        arglist (mapv (comp symbol #(string/replace % "_" "-") :name) params)
        target (clojure-name name)]
    ;; A name clojure.core has too (assert, declare) is this namespace's own.
    (when-let [existing (get (ns-map *ns*) target)]
      (when-not (and (var? existing) (= *ns* (.ns ^clojure.lang.Var existing))) (ns-unmap *ns* target)))
    (intern *ns*
            (with-meta (clojure-name name) {:doc (str doc "\n\n" name ": " (json/write-str (mapv :type params)))
                                            :arglists (list arglist)})
            (fn [& values] (call @method function (vec values))))))
