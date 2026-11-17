;; SPDX-License-Identifier: MIT
;; determinismo's debugger at a moment (docs/DEBUGGING.md), from Clojure, babashka or jank: a
;; session of serve's held at a moment of a timeline, the VMM's looks and changes as data. The
;; machine stays stopped between calls; only `sh`, `step-branches` and `continue` move the guest,
;; and stops change nothing of the recorded history.
;;
;;   (require '[determinismo.debug :as dbg])
;;   (binding [dbg/*url* "http://127.0.0.1:7878"] ...)    ; $DETERMINISMO_URL, else this
;;   (def s (dbg/open 13 {:branch 0 :until "event=composer_start"}))
;;   (dbg/regs s)                                       ; {:rip "0x..." :cr3 "0x..." ...}
;;   (dbg/translate s :current 0xffffffff824079c0)      ; 0x24079c0 (jiffies)
;;   (dbg/mem s 0x24079c0 8) (dbg/poke s 0x24079c0 [0 0 0 0])
;;   (dbg/break s 0xffffffff81b96960) (dbg/continue s)  ; stopped on the kernel's schedule
;;   (dbg/step-branches s 1000) (dbg/sh s "det-nodes list")
;;   (dbg/checkpoint s "loaded")                        ; the machine saved here
;;   (dbg/close s)
;;   (def s2 (dbg/resume 13 s "loaded"))                ; back there, not from boot
;;
;; A run replays with the explorer that recorded it: these answer in runs recorded since they
;; exist (2026-11-13); an older run's guest takes them for shell commands.
(ns determinismo.debug
  (:require [clojure.string :as str]
            [determinismo.http :as http]
            [determinismo.json :as json]
            [determinismo.tap :as tap]))

(def ^:dynamic *url* http/url) ; $DETERMINISMO_URL, else http://127.0.0.1:7878

(defn- call [path body]
  (let [[status text] (http/request :post (str *url* path) (json/write-json body))]
    (when (>= status 400)
      (throw (ex-info (str "determinismo: " status " " text) {:status status :body text})))
    (json/read-json text)))

(def ^:private timelines (atom {}))

(declare plan-session open-session)

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

(defn continue
  "On until the breakpoint (or `ms` of virtual time, 60 s by default): where it stopped,
  {:rip :cr3 :vtime_ns :branches}, or nil when the time ran out first."
  ([session] (continue session nil))
  ([session ms]
   (let [stopped (answer (step* session (str "det:continue" (when ms (str " " ms)))) "break")]
     (tap/tell :stop {:session session :at stopped} stopped))))

(defn step-branches
  "On `n` taken branches (jumps, calls, returns), stopped there: the registers then."
  [session n]
  (step* session (str "det:step " n))
  (regs session))

(defn sh
  "A command in the guest at the session's moment (`det-nodes exec <node> ...` for a node's):
  what it printed. The guest runs while it does."
  [session command]
  (let [raw (or (step* session command) "")
        said (->> (str/split-lines raw)
                  (keep (fn [line]
                          (when-let [at (str/index-of line "{\"event\":\"exec_output\"")]
                            (get-in (json/read-json (subs line at)) [:details :text]))))
                  (apply str))]
    (tap/tell :sh {:session session :command command :said said :output raw} said)))

(defn nodes
  "The system's nodes at the session's moment: [{:name :state :pid :address :image} ...]."
  [session]
  (->> (str/split-lines (sh session "det-nodes list"))
       (remove str/blank?)
       (mapv json/read-json)))
