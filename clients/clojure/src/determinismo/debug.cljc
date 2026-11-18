;; SPDX-License-Identifier: MIT
;; determinismo's debugger at a moment (docs/DEBUGGING.md), from Clojure, babashka or jank: a
;; session of serve's held at a moment of a timeline, the VMM's looks and changes as data. The
;; machine stays stopped between calls; only `sh`, `step-branches` and `continue` move the guest,
;; and stops change nothing of the recorded history.
;;
;;   (require '[determinismo.debug :as dbg])
;;   (binding [api/*url* "http://127.0.0.1:7878"] ...)    ; $DETERMINISMO_URL, else this: one
;;                                                      ; address for every namespace and the viz
;;   (def s (dbg/open 13 {:branch 0 :until "event=composer_start"}))
;;   (dbg/regs s)                                       ; {:rip "0x..." :cr3 "0x..." ...}
;;   (dbg/translate s :current 0xffffffff824079c0)      ; 0x24079c0 (jiffies)
;;   (dbg/mem s 0x24079c0 8) (dbg/poke s 0x24079c0 [0 0 0 0])
;;   (dbg/break s 0xffffffff81b96960) (dbg/continue s)  ; stopped on the kernel's schedule
;;   (dbg/watch-values s 0xffffffff824079c0 8 {:limit 3}) ; jiffies' next three writes, each a moment
;;   (dbg/watch-values s address 8 {:cr3 cr3 :type :f64 :keep? #(< 35.0 % 40.3)})
;;   (dbg/watch-values s (dbg/symbol s "db-1" "counter") {:keep? #(> % 100)}) ; by its name
;;   (dbg/step-branches s 1000) (dbg/sh s "det-nodes list")
;;   (dbg/checkpoint s "loaded")                        ; the machine saved here
;;   (dbg/close s)
;;   (def s2 (dbg/resume 13 s "loaded"))                ; back there, not from boot
;;
;; A run replays with the explorer that recorded it: these answer in runs recorded since they
;; exist (2026-11-13); an older run's guest takes them for shell commands.
(ns determinismo.debug
  (:refer-clojure :exclude [symbol])
  (:require [clojure.string :as str]
            [determinismo.api :as api]
            [determinismo.http :as http]
            [determinismo.json :as json]
            [determinismo.tap :as tap]))

(defn- call [path body]
  (let [[status text] (http/request :post (str api/*url* path) (json/write-json body))]
    (when (>= status 400)
      (throw (ex-info (str "determinismo: " status " " text) {:status status :body text})))
    (json/read-json text)))

(def ^:private timelines (atom {}))

(declare plan-session open-session sh process-stop? continue)

(defn open
  "A session held at a moment of `run`'s timeline: its id. The moment: :until, a condition on
  its events (the query language: \"event=core_dump details.node=nrepl\"), with its temporal
  conditions (:preceded-by, :not-preceded-by, :followed-by, :not-followed-by another, :within
  seconds: the last connection opened is {:until \"event=ingress_open\" :not-followed-by
  \"event=ingress_open\"}), :rewind-ms before the first that matches; or :at-vtime-ms when a
  time itself is meant. With
  :fresh-seed, what comes after the moment is drawn anew from that seed (the recorded future's
  faults and scheduling not replayed past it): a what-if from the moment. With :ingress
  {:node :port :listen}, the session runs live and serve listens on `listen` (\"ip:port\")
  for connections into the node's port: a REPL inside the guest, reached from outside. A live session pauses its scenario (drivers, faults) unless :scenario
  :running. With :plan true nothing is opened: what it would do (the timeline it would be, where
  its replay starts and how long that takes), a plan `execute` opens."
  [run {:keys [branch at-vtime-ms until preceded-by not-preceded-by followed-by not-followed-by
               within rewind-ms fresh-seed ingress scenario plan] :as asked}]
  (if plan
    (plan-session run asked)
    (open-session run asked)))

(defn- session-request [{:keys [branch at-vtime-ms until preceded-by not-preceded-by followed-by
                                not-followed-by within rewind-ms fresh-seed ingress scenario]}]
  (cond-> {:branch branch}
    at-vtime-ms (assoc :at_vtime_ms at-vtime-ms)
    until (assoc :until until)
    preceded-by (assoc :preceded_by preceded-by)
    not-preceded-by (assoc :not_preceded_by not-preceded-by)
    followed-by (assoc :followed_by followed-by)
    not-followed-by (assoc :not_followed_by not-followed-by)
    within (assoc :within within)
    rewind-ms (assoc :rewind_ms rewind-ms)
    scenario (assoc :scenario (name scenario))
    fresh-seed (assoc :fresh_seed fresh-seed)
    ingress (assoc :ingress ingress)))

(defn- plan-session
  "What `open` would do, done nothing: {:plan true :timeline (the number it would take) :extends
  :at_vtime_ms :from (\"snapshot\" | \"boot\") :from_vtime_ms :replay_ms :wall_ms (about, at the
  timeline's pace) :live}, with what to give `execute`."
  [run asked]
  (let [planned (assoc (call (str "/runs/" run "/session") (assoc (session-request asked) :plan true))
                       :run run :open (dissoc asked :plan))]
    (tap/tell :session/plan planned planned)))

(defn execute
  "A plan made real: the session it planned, opened (its id)."
  [planned]
  (open-session (:run planned) (:open planned)))

(defn- open-session
  [run {:keys [branch at-vtime-ms until preceded-by not-preceded-by followed-by not-followed-by
               within rewind-ms] :as asked}]
  (let [answer (call (str "/runs/" run "/session") (session-request asked))]
    (when (:done answer)
      (throw (ex-info "determinismo: the session ended at once" {:output (:output answer)})))
    (swap! timelines assoc (:session answer) (:timeline answer))
    (tap/tell :session/open
              {:run run :session (:session answer) :timeline (:timeline answer) :branch branch
               :at-vtime-ms at-vtime-ms :until until :rewind-ms rewind-ms
               :preceded-by preceded-by :not-preceded-by not-preceded-by
               :followed-by followed-by :not-followed-by not-followed-by :within within}
              (:session answer))))

(defn timeline
  "The timeline a session records in its run, under the run's next number: the one it was opened
  on up to its moment, its own from there (its steps, what came in from outside). A timeline like
  any other: its events are queried, and a session opens on it at any of its moments
  ({:branch (timeline s) :until ...})."
  [session]
  (get @timelines session))

(defn- step*
  [session exec]
  (:output (call (str "/sessions/" session "/step") {:exec exec})))

(defn step
  "One step at the session's moment (a guest command, or a det: step): its output, raw."
  [session exec]
  (let [output (step* session exec)]
    (tap/tell :step {:session session :exec exec :output output} output)))

(defn close
  "Ends the session (its machine stopped): {:session :done}."
  [session]
  (let [ended (select-keys (call (str "/sessions/" session "/end") {}) [:session :done])]
    (tap/tell :session/close {:session session :timeline (get @timelines session)} ended)))

(def ^:private hex-digits "0123456789abcdef")

#?(:jank
   (cpp/raw "
#include <string>

// A non-negative integer's decimal digits as 0x... (up to 2^128: an address, a hash).
std::string determinismo_debug_hex(std::string const &decimal) {
  unsigned __int128 n = 0;
  for (char c : decimal) {
    if (c < '0' || c > '9') return std::string();
    n = n * 10 + static_cast<unsigned>(c - '0');
  }
  if (n == 0) return \"0x0\";
  std::string out;
  while (n > 0) {
    out.insert(out.begin(), \"0123456789abcdef\"[static_cast<unsigned>(n % 16)]);
    n /= 16;
  }
  return \"0x\" + out;
}
"))

(defn- hex
  "0x... for an address, kernel ones (0xffffffff8...) included, whatever number type holds them.
  On jank through C++ from its digits: jank's quot of a big integer goes through a double
  ((quot 9007199254740993N 1) is 9007199254740992), its low bits gone."
  [n]
  (if (string? n)
    n
    #?(:jank (str (cpp/determinismo_debug_hex (cpp/cast cpp/std.string (str (bigint n)))))
       :default (loop [n (bigint n) out ""]
                  (if (zero? n)
                    (str "0x" (if (= out "") "0" out))
                    (recur (quot n 16) (str (nth hex-digits (int (mod n 16))) out)))))))

(defn- unhex
  "The number a 0x... text is, exact: summed as a bigint (a kernel's addresses pass 2^63), a long
  when it fits one."
  [text]
  (let [digit (fn [c] (str/index-of hex-digits (str/lower-case (str c))))
        n (reduce (fn [n c] (+ (* n 16) (digit c))) 0N (subs text 2))]
    (if (<= n 9223372036854775807) (long n) n)))

(defn- answer
  "The JSON a det: step printed (`[determinismo] <kind>: {...}`), as a map; an error the VMM
  answered (`[determinismo] debug: {...}`) thrown."
  [output kind]
  (let [lines (str/split-lines (or output ""))
        prefix (str "[determinismo] " kind ": ")
        failed (some #(when (str/starts-with? % "[determinismo] debug: ") %) lines)]
    (when failed
      (throw (ex-info (str "determinismo: " failed) {:output output})))
    (when-let [line (some #(when (str/starts-with? % prefix) %) lines)]
      (json/read-json (subs line (count prefix))))))

(defn checkpoint
  "The machine saved where a session can come back to: its timeline 1 ns on, an event there
  (session_checkpoint, `name` its details' name), the machine among the run's replay snapshots
  (what a replay starts from instead of boot), then on to that millisecond's end. A session
  opened on the timeline at the event starts from it (`resume`): after a crash, a wedged
  process or an experiment gone wrong, back to the step after an expensive load (a library's,
  a JVM's warm-up) in about the time the snapshot takes to load. -> {:name :vtime_ns :saved}"
  ([session] (checkpoint session ""))
  ([session name]
   (let [found (answer (step* session (str "det:checkpoint " name)) "checkpoint")]
     (tap/tell :checkpoint {:session session :timeline (get @timelines session) :checkpoint found}
               found))))

(defn resume
  "A session at `session`'s last checkpoint named `name` (that session ended or not: its
  timeline is the run's), with `open`'s options (:exec, :live, :ingress ...): its id."
  ([run session name] (resume run session name {}))
  ([run session name options]
   (let [named (str "event=session_checkpoint details.name=\"" name "\"")]
     (open run (merge options {:branch (timeline session) :until named
                               :not-followed-by named})))))

(defn regs
  "The vCPU's registers: {:rip :rsp ... :cr3 :vtime_ns :branches}, registers as hex strings."
  [session]
  (let [found (answer (step* session "det:regs") "regs")]
    (tap/tell :regs {:session session :regs found} found)))

(defn translate
  "A virtual address's physical one, through `space`'s page tables (a cr3 from regs or a watch
  hit, or :current); nil when not mapped."
  [session space virtual]
  (let [space (if (= space :current) "current" (hex space))
        physical (:physical (answer (step* session (str "det:translate " space " " (hex virtual))) "translate"))
        address (when physical (unhex physical))]
    (tap/tell :translate {:session session :virtual (hex virtual) :physical physical} address)))

(defn mem
  "`size` bytes of guest physical memory at `address` (4096 at most), as a vector of 0-255."
  [session address size]
  (let [text (:hex (answer (step* session (str "det:mem " (hex address) " " size)) "mem"))]
    (when-not text (throw (ex-info "determinismo: no such guest memory" {:address address :size size})))
    (let [bytes (mapv (fn [pair] (unhex (str "0x" (apply str pair)))) (partition 2 text))]
      (tap/tell :mem {:session session :address (hex address) :bytes bytes} bytes))))

(defn poke
  "Writes `bytes` (0-255 each) at guest physical `address`, recorded with its moment:
  {:address :bytes}."
  [session address bytes]
  (let [output (step* session (str "det:poke " (hex address) "="
                                   (apply str (map (fn [b] (str (nth hex-digits (quot b 16)) (nth hex-digits (mod b 16)))) bytes))))]
    (when-not (str/includes? (or output "") "[determinismo] poke: ")
      (throw (ex-info (str "determinismo: the poke was refused: " output) {:output output})))
    (tap/tell :poke {:session session :address (hex address) :bytes (vec bytes)}
              {:address (hex address) :bytes (vec bytes)})))

(defn break
  "A hardware breakpoint at a guest virtual address (in address space `cr3`, or any); nil: off."
  ([session address] (break session address nil))
  ([session address cr3]
   (answer (step* session (str "det:break " (if address (str (hex address) (when cr3 (str " " (hex cr3)))) "off"))) "break")))

(defn watch
  "A hardware write watchpoint on `size` bytes (1, 2, 4 or 8, aligned to their size) at a guest
  virtual address (in address space `cr3`, or any); `continue` then stops after each write
  there, with the bytes written. (watch session nil): off."
  ([session address] (watch session address nil nil))
  ([session address size] (watch session address size nil))
  ([session address size cr3]
   (answer (step* session (str "det:watch " (if address (str (hex address) " " size (when cr3 (str " " (hex cr3)))) "off"))) "break")))

(defn continue
  "On until the breakpoint or a watched write (or `ms` of virtual time, 60 s by default): where
  it stopped, {:rip :cr3 :vtime_ns :branches}, a write's with :watch :size and :hex (the bytes
  written, memory order), or nil when the time ran out first."
  ([session] (continue session nil))
  ([session ms]
   (let [stopped (answer (step* session (str "det:continue" (when ms (str " " ms)))) "break")]
     (tap/tell :stop {:session session :at stopped} stopped))))

(defn- power-of-two
  "2.0 to the `e` (an integer, negative or not): exact for a float's exponents."
  [e]
  (loop [e e v 1.0]
    (cond (pos? e) (recur (dec e) (* v 2.0))
          (neg? e) (recur (inc e) (/ v 2.0))
          :else v)))

(defn- float-of
  "An IEEE 754 float from its sign, biased exponent (`top` all ones) and fraction (the
  mantissa over 2 to its width, in [0, 1))."
  [negative exponent fraction bias top]
  (let [magnitude (cond (= exponent top) (if (zero? fraction) ##Inf ##NaN)
                        (zero? exponent) (* fraction (power-of-two (- 1 bias)))
                        :else (* (+ 1.0 fraction) (power-of-two (- exponent bias))))]
    (if negative (- magnitude) magnitude)))

(defn value-of
  "Bytes (0-255 each, memory order: x86's little-endian) as a `type`'s number: :u8 :u16 :u32
  :u64, :i8 :i16 :i32 :i64 (two's complement), :f32 :f64 (IEEE 754). Built from the bytes
  themselves: integers summed as big integers, a float's mantissa as a double (exact: 53 bits).
  On jank a product of two integers that each fit 32 bits is taken in 32 ((* 46137344 256) is
  -1073741824, 2026-11-18), and a big integer's quotient goes through a double."
  [bytes type]
  (let [bytes (vec bytes)
        unsigned (reduce (fn [n b] (+ (* n 256) b)) 0N (reverse bytes))
        fit (fn [n] (if (and (<= n 9223372036854775807) (>= n -9223372036854775808)) (long n) n))
        span (reduce * 1N (repeat (* 8 (count bytes)) 2))]
    (case type
      (:u8 :u16 :u32 :u64) (fit unsigned)
      (:i8 :i16 :i32 :i64) (fit (if (>= (peek bytes) 128) (- unsigned span) unsigned))
      :f32 (let [[b0 b1 b2 b3] bytes
                 low (reduce (fn [f b] (/ (+ f b) 256.0)) 0.0 [b0 b1])]
             (float-of (>= b3 128) (+ (* (mod b3 128) 2) (quot b2 128))
                       (/ (+ (mod b2 128) low) 128.0) 127 255))
      :f64 (let [[b0 b1 b2 b3 b4 b5 b6 b7] bytes
                 low (reduce (fn [f b] (/ (+ f b) 256.0)) 0.0 [b0 b1 b2 b3 b4 b5])]
             (float-of (>= b7 128) (+ (* (mod b7 128) 16) (quot b6 16))
                       (/ (+ (mod b6 16) low) 16.0) 1023 2047))
      (throw (ex-info (str "determinismo: no such value type " type) {:type type})))))

(defn- named
  "A node's or a symbol's name as text, given as a string, a keyword or a symbol (:echo,
  'echo and \"echo\" alike)."
  [x]
  (if (or (keyword? x) (symbol? x)) (clojure.core/name x) (str x)))

(defn symbol
  "Where a variable (or function) of a node's processes is, by its name, at the session's
  moment (`det-nodes symbol`): {:pid :module :address :size :kind :physical :type :probe},
  the address in that process, :physical its page's guest physical address now (nil until
  the process first touched it), :type its type from the module's DWARF ({:kind :size :name};
  nil without DWARF), a function's :params ([{:name :kind :size :type}], in order, from DWARF),
  :probe a page of the process's own ({:address :physical}: its stack's
  top) that tells its address space from any other at a stop. Options: :field, a path into
  it (\"stats.accepted\", \"table[2].key\": that field's address, size and type); :pid, the
  process (else the first of the node's that defines the name). The node and the name are
  strings, keywords or symbols. `watch-values` (a variable, read as its type) and `calls` (a
  function) take it whole."
  ([session node wanted] (symbol session node wanted {}))
  ([session node wanted options]
   (let [node (named node)
         wanted (named wanted)
         said (sh session (str "det-nodes symbol " node " " wanted
                               (when (:field options) (str " --field " (:field options)))
                               (when (:pid options) (str " --pid " (:pid options)))))
         line (some (fn [l] (when (str/starts-with? l "{") l)) (str/split-lines (or said "")))]
     (when-not line
       (throw (ex-info (str "determinismo: " node " has no " wanted ": " said) {:node node :name wanted :said said})))
     (let [found (json/read-json line)]
       (tap/tell :symbol {:session session :node node :name wanted :found found} found)))))

(defn- value-type
  "A symbol's DWARF type (its :type) as value-of's type, or nil (an aggregate, no DWARF)."
  [described]
  (let [kind (:kind described)
        size (:size described)]
    (cond (= kind "signed") (get {1 :i8 2 :i16 4 :i32 8 :i64} size)
          (or (= kind "unsigned") (= kind "boolean") (= kind "pointer")) (get {1 :u8 2 :u16 4 :u32 8 :u64} size)
          (= kind "float") (get {4 :f32 8 :f64} size)
          :else nil)))

(def ^:private integer-registers
  "Where x86-64's calling convention puts a function's integer and pointer arguments, in order."
  [:rdi :rsi :rdx :rcx :r8 :r9])

(def ^:private vector-registers
  "Where it puts floating-point ones (each read in its low 64 bits: det:regs, a collected hit)."
  [:xmm0 :xmm1 :xmm2 :xmm3 :xmm4 :xmm5 :xmm6 :xmm7])

(defn- register-bytes
  "A register's value (\"0x...\") as its 8 bytes in memory order (little-endian)."
  [said]
  (let [text (str said)
        digits (if (str/starts-with? text "0x") (subs text 2) text)
        padded (str (apply str (repeat (- 16 (count digits)) "0")) digits)]
    (vec (reverse (map (fn [pair] (unhex (str "0x" (apply str pair)))) (partition 2 padded))))))

(defn- parameter-values
  "A call's parameters (a `symbol`'s :params, from DWARF) by x86-64's calling convention, at the
  function's entry: an integer, a pointer or a boolean in the next of rdi rsi rdx rcx r8 r9,
  a float in the next of xmm0 ... xmm7, each read as its type; from an aggregate passed by
  value on, where each is not known (nil). A register the answer does not have (an explorer
  before the vector registers) gives nil. -> [{:name :type :value} ...]"
  [params registers]
  (loop [params params next-integer 0 next-vector 0 placed true out []]
    (if (empty? params)
      out
      (let [param (first params)
            kind (:kind param)
            integer (contains? #{"signed" "unsigned" "boolean" "pointer"} kind)
            float (= kind "float")
            type (value-type param)
            register (when (and placed type)
                       (cond (and integer (< next-integer (count integer-registers)))
                             (get registers (nth integer-registers next-integer))
                             (and float (< next-vector (count vector-registers)))
                             (get registers (nth vector-registers next-vector))
                             :else nil))
            value (when register (value-of (subvec (register-bytes register) 0 (:size param)) type))]
        (recur (rest params)
               (if integer (inc next-integer) next-integer)
               (if float (inc next-vector) next-vector)
               (and placed (or integer float))
               (conj out {:name (:name param) :type (:type param) :value value}))))))

;; A top-level name: jank cannot capture a local bound to a string literal in a closure.
(def ^:private hit-prefix "[determinismo] hit: ")

(defn- collected
  "The hits a det:collect said as they passed ({:vtime_ns :branches :rip :cr3} and a write's
  :watch :size :hex, a call's :rdi ... :r9), and its count ({:hits :dropped})."
  [output]
  {:hits (vec (keep (fn [line] (when (str/starts-with? line hit-prefix) (json/read-json (subs line (count hit-prefix)))))
                    (str/split-lines (or output ""))))
   :said (answer output "collect")})

(defn- first-in-process
  "On to the first stop in the process `probe` names (det:continue, the others passed, at most
  `most` of them): [its address space (cr3), the stop], or [nil nil] when none came within
  `ms` of virtual time."
  [session probe ms most]
  (loop [passed 0]
    (let [stop (continue session ms)]
      (cond (or (nil? stop) (>= passed most)) [nil nil]
            (process-stop? session probe nil stop) [(:cr3 stop) stop]
            :else (recur (inc passed))))))

(defn- window
  "The hits from the session's moment on, in one request a window: armed with `arm!` (called
  with an address space or nil), a stop in the probe's process first when there is a probe
  and no address space given (one det:continue a stop until its address space is known, then
  armed to it), then det:collect over :ms of virtual time (10 s). -> {:stops [...] :dropped n}"
  [session probe arm! options]
  (let [ms (or (:ms options) 10000)
        given (:cr3 options)]
    (arm! given)
    (let [[space first-stop] (if (and probe (nil? given))
                               (first-in-process session probe ms (or (:max-stops options) 10000))
                               [given nil])
          searched (and probe (nil? given))]
      (when (and searched space) (arm! space))
      (if (and searched (nil? space))
        {:stops [] :dropped 0}
        (let [{:keys [hits said]} (collected (step* session (str "det:collect " ms)))]
          {:stops (vec (concat (when first-stop [first-stop]) hits))
           :dropped (or (:dropped said) 0)})))))

(defn watch-values
  "A variable's writes from the session's moment on: a write watchpoint on its `size` bytes at
  `address` (a guest virtual address), each write's value read as :type (:i8 ... :i64 by size
  unless given; :u8 ... :u64, :f32, :f64) and kept when :keep? holds for it, the first :limit
  (100) of them. The writes of :ms of virtual time (10 s), said as they pass in one request (a
  window: det:collect, 10,000 at most, the rest counted in the tap's :dropped); the watch is
  off after, the session at the window's end. :cr3 keeps one address space's writes (a
  process's: regs' or a stop's :cr3), else any. Each kept write is an exact moment of the
  timeline (its :vtime_ns and :branches, the guest just past the writing instruction at :rip),
  where a session can be opened. -> [{:value :vtime_ns :branches :rip :cr3} ...]

  Or a `symbol`'s answer in place of address and size: its process's writes alone, each read
  as the symbol's DWARF type (its :type) unless :type is given. The first
  write in the process's address space (its :probe page translates there) is stopped at, the
  others passed, and the window keeps to that address space (its :cr3)."
  ([session address-or-symbol] (watch-values session address-or-symbol nil {}))
  ([session address size-or-options]
   (if (map? address)
     (watch-values session address nil size-or-options)
     (watch-values session address size-or-options {})))
  ([session address size options]
   (let [named (when (map? address) address)
         address (if named (:address named) address)
         size (if named (:size named) size)
         type (or (:type options) (value-type (:type named)) (get {1 :i8 2 :i16 4 :i32 8 :i64} size))
         keep? (or (:keep? options) (fn [_] true))
         limit (or (:limit options) 100)
         {:keys [stops dropped]} (window session (:probe named) (fn [space] (watch session address size space)) options)
         kept (->> stops
                   (filter :hex)
                   (map (fn [stop]
                          (let [bytes (mapv (fn [pair] (unhex (str "0x" (apply str pair)))) (partition 2 (:hex stop)))]
                            (assoc (select-keys stop [:vtime_ns :branches :rip :cr3]) :value (value-of bytes type)))))
                   (filter (fn [write] (keep? (:value write))))
                   (take limit)
                   vec)]
     (watch session nil)
     (tap/tell :watch-values {:session session :address (hex address) :size size :type type :kept kept
                              :dropped dropped}
               kept))))

(defn- process-stop?
  "Whether a stop is in the process `probe` names (its page translates to the probe's physical
  one in the stop's address space), once its address space `space` is known simply that; no
  probe: any stop."
  [session probe space stop]
  (or (nil? probe) (some? space)
      (= (unhex (:physical probe)) (translate session (:cr3 stop) (:address probe)))))

(defn calls
  "A function's calls from the session's moment on: a breakpoint at a `symbol`'s function
  (its entry, in its process's address space), each call's arguments the registers of
  x86-64's calling convention ({:args [rdi rsi rdx rcx r8 r9]}, as numbers: an integer's or a
  pointer's; a float's are in vector registers, not read), kept when :keep? holds for :args,
  the first :limit (100) of them. The calls of :ms of virtual time (10 s), said as they pass in
  one request (a window, as watch-values'), the first in the process stopped at to learn its
  address space; the breakpoint is off after. Each kept call is an exact moment, the
  function's first instruction not run yet. With the module's DWARF (the symbol's :params),
  :params says them by name, each read as its type ([{:name \"client\" :type \"i32\" :value 5}],
  a float's from its vector register). -> [{:args :params :vtime_ns :branches :rip :cr3} ...]"
  ([session found] (calls session found {}))
  ([session found options]
   (let [address (:address found)
         keep? (or (:keep? options) (fn [_] true))
         limit (or (:limit options) 100)
         {:keys [stops dropped]} (window session (:probe found) (fn [space] (break session address space)) options)
         kept (->> stops
                   (filter :rdi)
                   (map (fn [stop]
                          (cond-> (assoc (select-keys stop [:vtime_ns :branches :rip :cr3])
                                         :args (mapv (fn [k] (unhex (get stop k))) integer-registers))
                            (:params found) (assoc :params (parameter-values (:params found) stop)))))
                   (filter (fn [call] (keep? (:args call))))
                   (take limit)
                   vec)]
     (break session nil)
     (tap/tell :calls {:session session :address (hex address) :kept kept :dropped dropped} kept))))

(defn across
  "`f` at a moment of each timeline of `run` an event query keeps: the timelines where
  `condition` (the query language, as `open`'s :until) matches, in the query's order, the
  first :most of them (8), or those of :branches. Each is opened as a session at its first
  match (:until condition, with :open's other options: :rewind-ms, :not-followed-by, ...),
  `f` called with the session, and the session closed after, also when `f` throws (the
  error then goes on). One session at a time: a session is a machine. Over the multiverse,
  a variable's values or a function's calls from the same moment in many timelines:
  (across 13 \"event=selftest_accepted\" (fn [s] (watch-values s (symbol s :echo :count))))
  -> [{:branch :matches :first_vtime_ns :timeline (the session's own) :result} ...]"
  ([run condition f] (across run condition f {}))
  ([run condition f options]
   (let [matched (api/query run {:condition condition :output "branches"})
         wanted (when (:branches options) (set (:branches options)))
         chosen (if wanted
                  (filterv (fn [row] (contains? wanted (:branch row))) matched)
                  (vec (take (or (:most options) 8) matched)))
         results (mapv (fn [row]
                         (let [session (open run (merge (:open options) {:branch (:branch row) :until condition}))
                               result (try (f session) (finally (close session)))]
                           (assoc (select-keys row [:branch :matches :first_vtime_ns])
                                  :timeline (timeline session) :result result)))
                       chosen)]
     (tap/tell :across {:run run :condition condition :timelines (count matched) :results results}
               results))))

(def ^:private rust-escapes
  [["$LT$" "<"] ["$GT$" ">"] ["$RF$" "&"] ["$BP$" "*"] ["$C$" ","] ["$u20$" " "] ["$u27$" "'"]
   ["$u5b$" "["] ["$u5d$" "]"] ["$u7b$" "{"] ["$u7d$" "}"] ["$u7e$" "~"] [".." "::"]])

(defn demangle
  "A symbol's path when it is a nested name (`_ZN<length><part>...E`: Rust's legacy mangling,
  C++'s namespaces), its Rust hash part dropped and Rust's escapes undone:
  _ZN10turso_core2io10Completion8complete17h735acbbdf5edf53fE is
  turso_core::io::Completion::complete. Anything else as it is."
  [mangled]
  (if-not (and (string? mangled) (str/starts-with? mangled "_ZN") (str/ends-with? mangled "E"))
    mangled
    (loop [at 3 parts []]
      (let [digits (apply str (take-while (fn [c] (str/includes? "0123456789" (str c))) (subs mangled at)))]
        (if (= "" digits)
          (let [parts (if (and (seq parts) (re-matches #"h[0-9a-f]{16}" (peek parts))) (pop parts) parts)]
            (if (empty? parts)
              mangled
              (str/join "::" (map (fn [part] (reduce (fn [text [from to]] (str/replace text from to)) part rust-escapes)) parts))))
          (let [n (parse-long digits)
                from (+ at (count digits))]
            (if (> (+ from n) (count mangled))
              mangled
              (recur (+ from n) (conj parts (subs mangled from (+ from n)))))))))))

(defn where
  "What holds each address in a node's processes (`det-nodes where`): its module and the function
  of its symbol table there, :name that function's path demangled, :offset how far in. A guest
  command: the session's future its own after it (look first). Options: :pid, the process.
  -> [{:address :module :symbol :name :offset} ...]"
  ([session node addresses] (where session node addresses {}))
  ([session node addresses options]
   (let [node (named node)
         found (vec (mapcat (fn [chunk]
                              (let [said (sh session (str "det-nodes where " node " " (str/join " " (map hex chunk))
                                                          (when (:pid options) (str " --pid " (:pid options)))))]
                                (keep (fn [line] (when (str/starts-with? line "{") (json/read-json line)))
                                      (str/split-lines (or said "")))))
                            (partition-all 150 addresses)))
         named-found (mapv (fn [one] (assoc one :address (unhex (:address one)) :name (demangle (:symbol one)))) found)]
     (tap/tell :where {:session session :node node :found named-found} named-found))))

(defn- little-u64
  "8 bytes in memory order (little-endian) as a number, exact: a long when it fits one (so it
  meets `unhex`'s numbers as map keys), else a bigint."
  [bytes]
  (let [n (reduce (fn [n b] (+ (* n 256) b)) 0N (reverse bytes))]
    (if (<= n 9223372036854775807) (long n) n)))

(defn frames
  "The calls a process is in, at a stop of the session's inside it (a breakpoint's or a watch's:
  the vCPU's registers are then that process's): the words of its stack from the stack pointer
  on (:pages of 4 KiB, 4) that point into a function of one of its modules, innermost first,
  named by `where` (a guest command after the stack is read). Return addresses only: a leaf
  function has none of its own, and a word a returned call left behind is named too. Options:
  :pid, :pages. -> [{:address :module :symbol :name :offset} ...]"
  ([session node] (frames session node {}))
  ([session node options]
   (let [registers (regs session)
         space (unhex (:cr3 registers))
         rsp (unhex (:rsp registers))
         start (- rsp (mod rsp 4096))
         words (vec (mapcat (fn [page]
                              (let [va (+ start (* page 4096))
                                    physical (translate session space va)]
                                (when physical
                                  (let [bytes (mem session physical 4096)]
                                    (keep (fn [i] (when (>= (+ va i) rsp) (little-u64 (subvec bytes i (+ i 8)))))
                                          (range 0 4096 8))))))
                            (range (or (:pages options) 4))))
         ;; User-space addresses only (below 2^47): the rest are data.
         candidates (vec (distinct (filter (fn [w] (and (>= w 4096) (< w 140737488355328))) words)))
         named-all (where session node candidates (select-keys options [:pid]))
         by-address (into {} (map (fn [one] [(:address one) one]) named-all))
         stack (vec (dedupe (keep (fn [w] (let [one (get by-address w)] (when (:symbol one) one))) words)))]
     (tap/tell :frames {:session session :node (named node) :frames stack} stack))))

(defn moment-when
  "The first moment of a timeline where `holds?` is true, by bisection: `holds?` is called with a
  session opened there (a fresh one each look, closed after), false at :from-ms and true at
  :to-ms; first to the millisecond, then to the taken branch (det:step on from the millisecond).
  Looks only in `holds?` (regs, translate, mem; a guest command makes the session's future its
  own): a session that runs no guest command is the recorded timeline (exact sessions; on an
  explorer before them a session's future parts slightly from the recording).
  -> {:ms :branches (taken after :ms) :regs (there)}"
  [run branch holds? {:keys [from-ms to-ms]}]
  (let [probe (fn [ms k]
                (let [s (open run {:branch branch :at-vtime-ms ms})]
                  (try
                    (when (pos? k) (step* s (str "det:step " k)))
                    [(boolean (holds? s)) (regs s)]
                    (finally (close s)))))
        [from-held _] (probe from-ms 0)
        [to-held _] (probe to-ms 0)]
    (when (or from-held (not to-held))
      (throw (ex-info "determinismo: moment-when wants false at :from-ms and true at :to-ms"
                      {:from-ms from-ms :from from-held :to-ms to-ms :to to-held})))
    (let [[lo hi] (loop [lo from-ms hi to-ms]
                    (if (<= (- hi lo) 1)
                      [lo hi]
                      (let [mid (quot (+ lo hi) 2)]
                        (if (first (probe mid 0)) (recur lo mid) (recur mid hi)))))
          [_ at-lo] (probe lo 0)
          [_ at-hi] (probe hi 0)
          span (- (:branches at-hi) (:branches at-lo))
          k (loop [blo 0 bhi span]
              (if (<= (- bhi blo) 1)
                bhi
                (let [mid (quot (+ blo bhi) 2)]
                  (if (first (probe lo mid)) (recur blo mid) (recur mid bhi)))))
          [_ at] (probe lo k)
          found {:ms lo :branches k :regs at}]
      (tap/tell :moment-when {:run run :branch branch :found found} found))))

(defn step-branches
  "On `n` taken branches (jumps, calls, returns), stopped there: the registers then."
  [session n]
  (step* session (str "det:step " n))
  (regs session))

(defn sh
  "A command in the guest at the session's moment (`det-nodes exec <node> ...` for a node's):
  what it printed. The guest runs while it does. Its own output only: a command left running
  (det:background) prints into later steps' output too, under its own id."
  [session command]
  (let [raw (or (step* session command) "")
        events (keep (fn [line]
                       (when-let [at (str/index-of line "{\"event\":\"exec_")]
                         (json/read-json (subs line at))))
                     (str/split-lines raw))
        ;; This step's command is the one it starts: the first exec_start in its output.
        id (some (fn [e] (when (= "exec_start" (:event e)) (get-in e [:details :id]))) events)
        said (->> events
                  (filter (fn [e] (and (= "exec_output" (:event e)) (some? id) (= id (get-in e [:details :id])))))
                  (map (fn [e] (get-in e [:details :text])))
                  (apply str))]
    (tap/tell :sh {:session session :command command :said said :output raw} said)))

(defn nodes
  "The system's nodes at the session's moment: [{:name :state :pid :address :image} ...]."
  [session]
  (->> (str/split-lines (sh session "det-nodes list"))
       (remove str/blank?)
       (mapv json/read-json)))

(defn node-sh
  "A shell command run inside `node` at the session's moment (its root, its namespaces, as the
  node's own processes see them): what it printed. A Go program's goroutines, for one:
  (node-sh s \"raft-node-0\" \"kill -QUIT 1\"), then its output as the timeline goes on."
  [session node command]
  (sh session (str "det-nodes exec " (named node) " sh -c '" (str/replace command "'" "'\\''") "'")))

(defn forks
  "The forks this session started (`sdk.fork` in a REPL at its moment): each fork's run, its
  futures, its state and verdicts."
  [session]
  (call (str "/sessions/" session "/forks") {}))

(defn latest
  "The last `event` (an event's name) the session's timeline said so far, as its events file has
  it ({:seq :vtime_ns :event}), or nil: what a window following a session draws from."
  [session event]
  (let [[status text] (http/request :get (str api/*url* "/sessions/" session "/latest?event=" event) nil)]
    (cond (= status 204) nil
          (>= status 400) (throw (ex-info (str "determinismo: " status " " text) {:status status :body text}))
          :else (json/read-json text))))
