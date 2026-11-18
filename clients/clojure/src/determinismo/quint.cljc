;; SPDX-License-Identifier: MIT
;; A timeline checked against a Quint spec kept here (docs/QUINT.md), from Clojure, babashka or
;; jank: serve gives the timeline's own events as a run of the spec's actions, Quint runs it
;; here, and serve says what its result means, as data.
;;
;;   (require '[determinismo.quint :as quint])
;;   (quint/kinds 12 0)                                    ; the names a timeline's events have
;;   (quint/check 12 0 "bank.qnt")                         ; {:kind "behavior" :events 1637 ...}
;;   (quint/check 12 0 "bank.qnt" {:invariant "total_conserved"})
;;   (quint/simulate "bank.qnt" {:invariant "total_conserved"})
;;
;; Needs Quint here (`npm install -g @informalsystems/quint`; `:quint` names another command).
(ns determinismo.quint
  (:require [clojure.string :as str]
            #?(:clj [clojure.java.shell :as shell])
            [determinismo.api :as api]
            [determinismo.json :as json]
            [determinismo.tap :as tap]))

#?(:jank
   (cpp/raw "
#include <array>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/wait.h>

// A shell command's \"<exit status>\\n<output>\" (its standard error with it, by the command).
std::string determinismo_quint_sh(std::string const &command) {
  std::string out;
  int status = -1;
  if (FILE *pipe = popen(command.c_str(), \"r\")) {
    std::array<char, 65536> buffer;
    size_t n;
    while ((n = fread(buffer.data(), 1, buffer.size(), pipe)) > 0) out.append(buffer.data(), n);
    int ended = pclose(pipe);
    status = WIFEXITED(ended) ? WEXITSTATUS(ended) : -1;
  }
  return std::to_string(status) + \"\\n\" + out;
}

// A file's content, or \"\" when it is not there.
std::string determinismo_quint_read(std::string const &path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return std::string();
  std::ostringstream content;
  content << file.rdbuf();
  return content.str();
}

void determinismo_quint_write(std::string const &path, std::string const &content) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file << content;
}

// A command read a line at a time as it prints: open, lines until \"\\x01\" (its end), close
// (its exit status).
static FILE *determinismo_quint_pipe = nullptr;
void determinismo_quint_open(std::string const &command) { determinismo_quint_pipe = popen(command.c_str(), \"r\"); }
std::string determinismo_quint_line() {
  std::string line;
  if (!determinismo_quint_pipe) return std::string(\"\\x01\");
  int c;
  bool any = false;
  while ((c = fgetc(determinismo_quint_pipe)) != EOF) {
    any = true;
    if (c == 10) return line;
    line.push_back(static_cast<char>(c));
  }
  return any ? line : std::string(\"\\x01\");
}
std::string determinismo_quint_close() {
  if (!determinismo_quint_pipe) return std::string(\"-1\");
  int ended = pclose(determinismo_quint_pipe);
  determinismo_quint_pipe = nullptr;
  return std::to_string(WIFEXITED(ended) ? WEXITSTATUS(ended) : -1);
}
"))

(defn- sh
  "[exit-status output] of a shell command."
  [command]
  #?(:clj (let [{:keys [exit out err]} (shell/sh "sh" "-c" command)]
            [exit (str out err)])
     :jank (let [answer (str (cpp/determinismo_quint_sh (cpp/cast cpp/std.string command)))
                 cut (str/index-of answer "\n")]
             [(parse-long (subs answer 0 cut)) (subs answer (inc cut))])))

(defn- each-line
  "Calls `f` with each line a shell command prints, as it prints it. Its exit status."
  [command f]
  #?(:clj (let [process (.start (doto (ProcessBuilder. ["sh" "-c" command]) (.redirectErrorStream true)))]
            (with-open [reader (java.io.BufferedReader. (java.io.InputStreamReader. (.getInputStream process)))]
              (loop []
                (when-let [line (.readLine reader)]
                  (f line)
                  (recur))))
            (.waitFor process))
     :jank (do (cpp/determinismo_quint_open (cpp/cast cpp/std.string command))
               (loop []
                 (let [line (str (cpp/determinismo_quint_line))]
                   (if (= line "\u0001")
                     (parse-long (str (cpp/determinismo_quint_close)))
                     (do (f line) (recur))))))))

(defn- read-file
  "A file's content, or nil when it is not there (or empty)."
  [path]
  (let [content #?(:clj (try (slurp path) (catch Exception _ ""))
                   :jank (str (cpp/determinismo_quint_read (cpp/cast cpp/std.string path))))]
    (when-not (= "" content) content)))

(defn- write-file [path content]
  #?(:clj (spit path content)
     :jank (cpp/determinismo_quint_write (cpp/cast cpp/std.string path) (cpp/cast cpp/std.string content))))

(defn- directory-of [path]
  (let [cut (str/last-index-of path "/")]
    (if cut (subs path 0 cut) ".")))

(defn- stem-of [path]
  (let [cut (str/last-index-of path "/")
        file (if cut (subs path (inc cut)) path)]
    (if (str/ends-with? file ".qnt") (subs file 0 (- (count file) 4)) file)))

(defn kinds
  "The names a timeline's own events have, in the order they first come: [{:name :count
  :example}], the example the first one's details as the argument an action of that name would
  get. What a spec could take as its actions."
  [run timeline]
  (let [given (json/read-json (api/request :post (str "/runs/" run "/quint")
                                           {:branch timeline :actions [] :main "spec"}))]
    (tap/tell :quint-kinds {:run run :timeline timeline :kinds (:kinds given)} (:kinds given))))

(defn check
  "Checks timeline `timeline` of run `run` against the Quint spec at `spec` (a path here). Beside
  the spec it leaves determinismo_trace.qnt (the timeline's events as a run of the spec's
  actions) and determinismo_trace.itf.json (the spec's states along it).
  Options: `:invariant` (a `val` of the spec, asked in the first state and after every event),
  `:main` (the spec's module when it is not named like its file), `:quint` (Quint's command).
  The verdict, a map:
    :kind    \"behavior\", \"refused\" (an event the spec does not take), \"invariant\" (lost after
             an event), \"unknown\" (Quint did not run it: :output says why), or \"nothing\" (no
             event is named like an action of the spec: :kinds lists the names there are)
    :status  0, 3 or 1, as `determinismo quint` exits
    :event   the event refused, or after which the invariant was lost: {:index (among the
             trace's :of events) :seq :vtime_ns :action :argument}
    :state   the spec's state there
    :series  each of the spec's numbers along the run ({:balances.0 [100 100 76 ...]})
    :text    the same in a sentence."
  ([run timeline spec] (check run timeline spec {}))
  ([run timeline spec options]
   (let [directory (directory-of spec)
         file (stem-of spec)
         quint (or (:quint options) "quint")
         asked (cond-> {:branch timeline
                        :spec (or (read-file spec) (throw (ex-info (str "no spec at " spec) {:spec spec})))
                        :main (or (:main options) file)
                        :file file}
                 (:invariant options) (assoc :invariant (:invariant options)))
         asked-json (json/write-json asked)
         path (str "/runs/" run "/quint")
         given (json/read-json (api/request :post path asked-json))
         told {:run run :timeline timeline :spec spec :invariant (:invariant options)}]
     (if (zero? (:events given))
       (let [verdict {:kind "nothing" :status 1 :events 0 :kinds (:kinds given)}]
         (tap/tell :quint-check (assoc told :verdict verdict) verdict))
       (let [states-path (str directory "/" (:states given))
             _ (write-file (str directory "/" (:file given)) (:module given))
             [status output] (sh (str "cd '" directory "' && rm -f " (:states given) " && " quint
                                      " test " (:file given) " --main determinismo_trace"
                                      " --match '^determinismo_trace_run$' --max-samples 1"
                                      " --out-itf " (:states given) " 2>&1"))
             states (read-file states-path)
             ;; The states as Quint wrote them, not read here: megabytes for a long timeline.
             body (str (subs asked-json 0 (dec (count asked-json)))
                       ",\"passed\":" (if (zero? status) "true" "false")
                       (when states (str ",\"states\":" states))
                       "}")
             verdict (cond-> (json/read-json (api/request :post path body))
                       (not (zero? status)) (assoc :output output))]
         (tap/tell :quint-check (assoc told :verdict verdict) verdict))))))

(defn- plain
  "A value of Quint's trace format as plain data: {\"#bigint\" \"7\"} a number, a map a map, a set
  or a tuple a vector; a state's \"#meta\" left out."
  [value]
  (cond
    (map? value)
    (let [big (get value (keyword "#bigint"))
          pairs (get value (keyword "#map"))
          items (or (get value (keyword "#set")) (get value (keyword "#tup")))]
      (cond
        big (or (parse-long big) big)
        pairs (into {} (map (fn [[k v]] [(plain k) (plain v)]) pairs))
        items (mapv plain items)
        :else (into {} (keep (fn [[k v]] (when-not (= k (keyword "#meta")) [k (plain v)])) value))))
    (sequential? value) (mapv plain value)
    :else value))

(defn simulate
  "Quint's simulator on the spec alone (`quint run`): does it find a state where `:invariant`
  does not hold? Options: `:invariant` (required), `:step` (another step action than `step`),
  `:max-samples`, `:max-steps`, `:quint`. {:violation true|false, :states (the run Quint found,
  or its last one: the spec's states as plain data), :output (what Quint printed)}."
  [spec options]
  (let [directory (directory-of spec)
        quint (or (:quint options) "quint")
        trace "determinismo_run.itf.json"
        [status output] (sh (str "cd '" directory "' && rm -f " trace " && " quint " run " (stem-of spec) ".qnt"
                                 " --invariant '" (:invariant options) "'"
                                 (when (:step options) (str " --step " (:step options)))
                                 (when (:max-samples options) (str " --max-samples " (:max-samples options)))
                                 (when (:max-steps options) (str " --max-steps " (:max-steps options)))
                                 " --out-itf " trace " 2>&1"))
        found (read-file (str directory "/" trace))
        states (if found (mapv plain (:states (json/read-json found))) [])
        answer {:violation (and (not (zero? status)) (str/includes? output "[violation]"))
                :status status
                :states states
                :output output}]
    (tap/tell :quint-simulate {:spec spec :invariant (:invariant options) :step (:step options)
                               :violation (:violation answer) :states states}
              answer)))

(def ^:private agent-steps
  "jq's program over Claude Code's stream of messages: what the agent runs and writes, and what
  its checks (./trace.sh, quint run) answer, a line each; its turns and seconds at the end."
  "\n  def short: gsub(\"\\n\"; \" \") | .[0:74];\n  def answers: split(\"\\n\")\n    | map(select(test(\"\\\\[determinismo\\\\] (the trace|the spec refuses|[a-z_]+ does not hold)|\\\\[violation\\\\]|\\\\[ok\\\\] No violation\")))\n    | .[0:3] | map(\"    \" + (sub(\"\\\\[determinismo\\\\] \"; \"\") | short));\n  foreach inputs as $m ({ran: {}, out: []};\n    .out = []\n    | if $m.type == \"assistant\" then\n        reduce ($m.message.content[]? | select(.type == \"tool_use\")) as $c (.;\n          .ran[$c.id] = ($c.input.command // \"\")\n          | .out += [if $c.name == \"Bash\" then \"$ \" + ($c.input.command | short)\n                     else ($c.name | ascii_downcase) + \" \" + (($c.input.file_path // \"\") | split(\"/\") | last) end])\n      elif $m.type == \"user\" then\n        reduce ($m.message.content[]? | select(.type == \"tool_result\")) as $c (.;\n          if (.ran[$c.tool_use_id] // \"\") | test(\"\\\\./trace\\\\.sh|quint run\") then\n            .out += ($c.content | if type == \"array\" then map(.text? // \"\") | join(\"\\n\") else tostring end | answers)\n          else . end)\n      elif $m.type == \"result\" then\n        .out += [\"agent done: \\($m.num_turns) turns, \\(($m.duration_ms // 0) / 1000 | floor) s\"]\n      else . end;\n    .out[])")

(defn agent
  "An agent (Claude Code: `claude -p`) at work in `directory` on the task its file `prompt`
  says, allowed to read and write files there and to run ./trace.sh (clients/quint), quint and
  a few shell tools: what writes a spec from a run's timelines with no source of the system.
  Each thing it runs and each answer of its checks is told as it comes (:quint-agent). Needs
  `claude` and `jq`. {:status (its exit status) :steps (how many lines it told) :said (its last
  one: its turns and seconds)}."
  [directory prompt]
  (let [steps (atom 0)
        said (atom nil)
        command (str "cd '" directory "' && claude -p \"$(cat '" prompt "')\""
                     " --permission-mode acceptEdits --max-turns 80"
                     " --allowedTools Read Write Edit 'Bash(./trace.sh:*)' 'Bash(quint:*)' 'Bash(cat:*)'"
                     " 'Bash(ls:*)' 'Bash(head:*)' 'Bash(tail:*)' 'Bash(grep:*)' 'Bash(jq:*)' 'Bash(wc:*)'"
                     " 'Bash(echo:*)' 'Bash(for:*)'"
                     " --output-format stream-json --verbose < /dev/null 2>/dev/null"
                     " | jq -rn --unbuffered '" agent-steps "'")
        status (each-line command (fn [line]
                                    (swap! steps inc)
                                    (reset! said line)
                                    (tap/tell :quint-agent {:directory directory :line line} nil)))]
    {:status status :steps @steps :said @said}))

(defn agent-told
  "A run of `agent` that was kept, told again: the lines it told (`file` in `directory`, one a
  line, as `agent` tells them and a kit's own script keeps them), at a pace one can read. For a
  run too long to make again where it is shown (a real system's: forty minutes). {:steps (how
  many lines) :said (the last: its turns and seconds)}."
  [directory file]
  (let [steps (atom 0)
        said (atom nil)
        command (str "while IFS= read -r line; do printf '%s\\n' \"$line\"; sleep 0.05; done < '"
                     directory "/" file "'")]
    (each-line command (fn [line]
                         (swap! steps inc)
                         (reset! said line)
                         (tap/tell :quint-agent {:directory directory :line line} nil)))
    {:steps @steps :said @said}))
