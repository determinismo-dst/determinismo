;; SPDX-License-Identifier: MIT
(ns determinismo.workload
  "Test programs in Clojure, as Zig's System (sdk/zig/system.zig): the system's profiles and
  nodes, its scenarios' commands and the host checks, defined as data, with libdeterminismo
  (determinismo.ffi) doing what it does for Zig programs: the definition checked and converted
  by the same code, decisions, assertions, records, faults and Elle.

  A program is a map, and its -main calls `main`:

    (def program
      {:profiles [{:name \"default\"
                   :nodes [[:db {:build {:context \".\" :dockerfile \"db/Dockerfile\"}
                                 :ready {:tcp 5432}}]
                           [:client {:build {:context \".\" :dockerfile \"client/Dockerfile\"}
                                     :after [:db]}]]}]
       ;; The JVM is a node's: commands run there, as `<program> run <scenario> <command>`.
       :node :client
       :program \"/opt/workload/run\"
       :scenarios [{:name \"bank\"
                    :commands [(w/parallel-driver \"transfer\" transfer)
                               (w/eventually \"balanced\" balanced)]}]
       :checks {:elle (w/elle-check {:consistency \"strict-serializable\"})}})

    (defn -main [& arguments] (w/main program arguments))

  Fault kinds of the program's own (Antithesis's custom faults), as functions:

       :custom-faults {\"rolling-restart\" rolling-restart}

  are in its node's faults (`<program> fault <name>`, Faults.custom): the fault injector picks
  them with its own decisions, as it picks its kinds, and runs each there to its end. A function
  acts on any node through the runner (`runner`, `node!`), its choices drawn from decisions:
  new platform mechanics, replayed as the platform's are.

  Node specs and scenario options are Zig's (system.zig's NodeSpec, schema.zig's Scenario) with
  dashes for underscores: :memory-max-mib, :crashes-known, :drive-ms-max. A command's function
  takes its context: {:scenario :command :profile}. A check's takes {:scenario :history}, the
  history being its records, one JSON line each (`records` reads them).

  Warm commands: the client node's command `<program> nrepl <port> 0.0.0.0` (its REPL) also takes
  the program's commands on 127.0.0.1:7889 (`serve-commands`), each run in that JVM; its
  launcher hands `run <scenario> <command>` to sdk/clojure/warm-run, a thin client the composer
  runs and kills as it would the command. A killed command ends at its
  next call into the SDK (`*killed*`). A program's :warm, a function, runs there first (before
  the node is ready, so in the setup's snapshot): its clients opened once, for every command.

  `zig build <name>` makes a program one file (build.zig's clojure_programs,
  tools/clojure_program.zig): a shell script and a jar of its sources with sdk/clojure, run on
  the host (--describe, checks) with Debian's Clojure, libdeterminismo given by determinismo
  (DETERMINISMO_LIBRARY). In a node, its image holds the sources and the libraries."
  (:refer-clojure :exclude [shuffle])
  (:require [clojure.string :as string]
            [determinismo.ffi :as ffi]
            [determinismo.json :as json]))

(set! *warn-on-reflection* true)

;; Commands ----------------------------------------------------------------------------------
;; Antithesis's test command kinds, as Zig's Scenario has them.

(defn- command [kind command-name f]
  {:kind kind :name command-name :run f})

(defn setup [command-name f] (command :setup command-name f))
(defn first-command [command-name f] (command :first command-name f))
(defn parallel-driver [command-name f] (command :parallel_driver command-name f))
(defn serial-driver [command-name f] (command :serial_driver command-name f))
(defn singleton-driver [command-name f] (command :singleton_driver command-name f))
(defn anytime [command-name f] (command :anytime command-name f))
(defn eventually [command-name f] (command :eventually command-name f))
(defn finally-command [command-name f] (command :finally command-name f))

;; Warm commands ----------------------------------------------------------------------------
;; A command run in the client node's long-lived JVM (`serve-commands`), its thin client the
;; composer's process: when that client goes (the composer ended the command), the command's
;; flag is set and it ends at its next call into the SDK, which a driver makes all the time.

(def ^:dynamic *killed*
  "The running command's flag (an atom), set once its client has gone; nil outside a warm
  command. Conveyed to the futures it starts."
  nil)

(defn- alive!
  "Throws in a command whose client has gone, so that it ends where it next calls the SDK."
  []
  (when-let [killed *killed*]
    (when @killed (throw (ex-info "the command was ended (its client gone)" {::killed true})))))

;; Randomness and decisions ------------------------------------------------------------------

(defn random-below
  "A uniformly random integer in [0, n): a platform decision; named (a string) for strategies."
  ([n] (alive!) (ffi/random-below n))
  ([decision n] (alive!) (ffi/random-below-named decision n)))

(defn random-float [] (alive!) (ffi/random-float))

(defn decide
  "One of options, a named decision: strategies see the name and each option's name."
  [decision options]
  (alive!)
  (nth options (ffi/decide decision (string/join "\n" (map #(if (keyword? %) (name %) (str %)) options)))))

(defn choice [items] (alive!) (nth items (ffi/random-below (count items))))

(defn swarm-index
  "An index below n (64 at most) by swarm testing, where random-below drew uniformly: the
  options this timeline keeps for the name, weighted, repeated in runs (the Zig SDK's
  swarm_index, the same table in every language)."
  [decision n]
  (alive!)
  (ffi/swarm-index decision n))

(defn random-near
  "A value up to max drawn around a limit the workload declares (a batch size, a buffer, a
  threshold): half the time uniform, else one of the limit's edges (0, 1, limit - 1, limit,
  limit + 1, twice it), named decisions (the Zig SDK's random_near)."
  [decision limit max]
  (alive!)
  (ffi/random-near decision limit max))

(defn swarm-choice
  "One of items by swarm testing (swarm-index)."
  [decision items]
  (let [items (vec items)] (nth items (swarm-index decision (count items)))))

(defn shuffle [items]
  (loop [items (vec items) i (dec (count items))]
    (if (pos? i)
      (let [j (ffi/random-below (inc i))]
        (recur (assoc items i (items j) j (items i)) (dec i)))
      items)))

(defn buggify [point] (ffi/buggify point))

;; Properties --------------------------------------------------------------------------------
;; Macros, so that each is in the program's catalog as its code loads (before it runs): one never
;; reached, or never true, in any timeline fails too. Messages are literals: the property's
;; identity.

(defn- declared [kind message]
  (when (and (string? message) (not *compile-files*))
    (ffi/declare kind message))
  message)

(defn assertion [kind condition message details]
  (alive!)
  (ffi/assert kind (boolean condition) message (if (nil? details) {} details)))

(defmacro always [condition message & [details]]
  `(assertion "always" ~condition ~(declared "always" message) ~details))

(defmacro always-or-unreachable [condition message & [details]]
  `(assertion "always_or_unreachable" ~condition ~(declared "always_or_unreachable" message) ~details))

(defmacro sometimes [condition message & [details]]
  `(assertion "sometimes" ~condition ~(declared "sometimes" message) ~details))

(defmacro reachable [message & [details]]
  `(assertion "reachable" true ~(declared "reachable" message) ~details))

(defmacro unreachable [message & [details]]
  `(assertion "unreachable" true ~(declared "unreachable" message) ~details))

(defn event [event-name details] (alive!) (ffi/event event-name (if (nil? details) {} details)))

(defn record
  "A record for the program's host check check-name: one JSON line, given to the check with the
  others when the timeline ends."
  [check-name value]
  (alive!)
  (ffi/record (name check-name) value))

;; Time and faults ---------------------------------------------------------------------------

(defn sleep-ms [ms] (alive!) (ffi/sleep-ms ms) (alive!))

(defn stop-faults
  "A quiet period of duration-ms (faults stop, the one under way undone); 0 ends it."
  [duration-ms]
  (ffi/stop-faults (* 1000000 (long duration-ms))))

(defn fault
  "A fault now: {:kind \"pause\" :node \"db\" :duration_ms 2000}, ... (guest/runtime/faults.zig).
  Only while the fault injector runs."
  [request]
  (ffi/fault request))

(defn fault-aim [node] (ffi/fault-aim (if (keyword? node) (name node) (str node))))

(defn explore-here!
  "From a fast VM (docs/DEVELOPING.md, a machine of serve's): this machine checkpointed as it
  stands and a run of deterministic timelines started from it, with faults, by serve (the
  machine's watcher). Blocks until it is started: {:run <id> :checkpoint <name>}, the run on
  serve's page. Options: :branches (16), :time-budget (\"10m\"). In those timelines the call
  never returns: they go on with the system's scenario."
  ([] (explore-here! {}))
  ([{:keys [branches time-budget] :or {branches 16}}]
   (alive!)
   (let [fifo (str "/opt/determinismo/records/.explore-" (.pid (java.lang.ProcessHandle/current)) "-" (System/nanoTime))]
     (.waitFor (.start (ProcessBuilder. ^java.util.List (vector "mkfifo" "-m" "666" fifo))))
     ;; Open (read and write: not blocking) before asking: the agent's write needs a reader.
     (with-open [answer (java.io.RandomAccessFile. fifo "rw")]
       (try
         (ffi/event "explore_request" (cond-> {:branches branches :reply fifo}
                                        time-budget (assoc :time_budget time-budget)))
         ;; The answer, a JSON line, written by the guest's agent for serve.
         (let [line (.readLine answer)
               [_ run] (re-find #"\"run\":(\d+)" line)
               [_ checkpoint] (re-find #"\"checkpoint\":\"([^\"]+)\"" line)]
           {:run (some-> run parse-long) :checkpoint checkpoint})
         (finally (.delete (java.io.File. fifo))))))))

(defn fork!
  "Clones this machine where it stands, as Unix's fork: n futures from this moment, each its own
  randomness, on other cores, while this one goes on. 0 here, k (1 to n) in future k. In a
  session (a REPL inside the guest) the platform clones the machine; elsewhere 0, nothing
  cloned."
  [n]
  (ffi/fork n))

;; The runner --------------------------------------------------------------------------------

(defn runner
  "A command run by the guest's runner, which sees every node (det-nodes start, stop, kill, crash,
  pause, exec; the network, the disks), from this program in its node: argv as words, :stdin
  given. {:status :stdout :stderr :truncated}, each request a runner_request event. Platform
  mechanics in Clojure are made of these and of decisions (decide, random-below): a fault kind,
  a node's lifecycle, a disk's table."
  ([argv] (runner argv {}))
  ([argv {:keys [stdin]}]
   (ffi/runner (cond-> {:argv (mapv #(if (keyword? %) (name %) (str %)) argv)} stdin (assoc :stdin stdin)))
   (json/read-str (String. ^bytes (ffi/runner-reply 65536) "UTF-8"))))

(defn node!
  "A node's lifecycle, from any node: action :start, :stop, :kill, :crash (a power loss),
  :wipe, :pause or :resume."
  [action node]
  (runner ["det-nodes" action node]))

(defn node-exec
  "A command in another node, as docker exec: {:status :stdout :stderr}."
  [node & argv]
  (runner (list* "det-nodes" "exec" node argv)))

(defn- runner-raw [request]
  (ffi/runner request)
  (json/read-str (String. ^bytes (ffi/runner-reply 65536) "UTF-8")))

(defn session
  "A runner command that outlives one request (det-runner's sessions: det-nodes hold, a tail of a
  log), opened: its id, for session-read, session-write and session-close."
  [argv]
  (get (runner-raw {:argv (mapv #(if (keyword? %) (name %) (str %)) argv) :session "open"}) "session"))

(defn session-read
  "A session's next line of output; nil at its end."
  [id]
  (get (runner-raw {:session "read" :id id}) "line"))

(defn session-write
  "Writes :input to a session's command and sends it :signal (\"USR1\", \"TERM\", ...)."
  [id {:keys [input signal]}]
  (runner-raw (cond-> {:session "write" :id id} input (assoc :input input) signal (assoc :signal signal))))

(defn session-close
  "Signals a session's command (TERM unless given) and forgets it."
  ([id] (session-close id "TERM"))
  ([id signal] (runner-raw {:session "close" :id id :signal signal})))

(defn hold
  "Holds threads of a node's process where points say (det-nodes hold: a function, then --caller,
  --arg, --repeat, --every, --direct, --and <function> ...), as the Zig SDK's Node.hold: armed
  before it returns. {:session :armed}; then held?, release-point, release."
  [node points timeout-ms]
  (let [id (session (concat ["det-nodes" "hold" (name node)] points ["--timeout-ms" (str timeout-ms)]))
        line (session-read id)]
    {:session id :armed (boolean (and line (.startsWith ^String line "{\"armed\":")))}))

(defn held?
  "Waits until a thread is held at point (0, 1, ...): true, or false when none will be."
  [{:keys [session]} point]
  (loop []
    (let [line (session-read session)]
      (cond
        (or (nil? line) (.startsWith ^String line "{\"held\":null")) false
        (and (.startsWith ^String line "{\"held\":") (.endsWith ^String line (str "\"point\":" point "}"))) true
        :else (recur)))))

(defn release-point
  "Lets point's held thread go on, the others held still."
  [{:keys [session]} point]
  (session-write session {:input (str "release " point "\n") :signal "USR1"}))

(defn release
  "Lets every held thread go and ends the hold."
  [{:keys [session]}]
  (session-close session))

;; serve, from inside a session ---------------------------------------------------------------

(defn serve
  "serve's API from inside a session's machine (this REPL in the guest): (serve :post \"/runs\"
  {...}), (serve :get \"/runs/12\"). {:status :body}, the body as data. Its reply is on the tape:
  a replay repeats it without serve. Throws outside a session."
  ([method path] (serve method path nil))
  ([method path body]
   (let [status (ffi/serve (string/upper-case (name method)) path (if (nil? body) "" body))
         text (String. ^bytes (ffi/serve-reply 16384) "UTF-8")]
     {:status status
      :body (if (string/blank? text) nil (try (json/read-str text) (catch Exception _ text)))})))

(defn start-run!
  "A run started from inside the machine, as POST /runs takes it ({:program :scenario :branches
  :time_budget ...}, the program a path on serve's host): its id, to follow with `run-state`."
  [request]
  (let [{:keys [status body]} (serve :post "/runs" request)]
    (when-not (= 201 status) (throw (ex-info "serve refused the run" {:status status :body body})))
    (:id body)))

(defn run-state
  "A run's state and stats, now (GET /runs/<id>)."
  [id]
  (:body (serve :get (str "/runs/" id))))

(defn fork-runs
  "The runs of the forks taken from run `run`'s sessions (fork!'s futures), newest last: their
  ids and states, to follow with `run-state`."
  [run]
  (filter #(= run (:from_run %)) (:body (serve :get "/runs"))))

;; The system --------------------------------------------------------------------------------

(defn system
  "The running system as determinismo resolved it (profile, nodes with their addresses,
  scenarios), nil outside determinismo."
  []
  (let [data (ffi/system 65536)]
    (when (pos? (alength ^bytes data))
      (json/read-str (String. ^bytes data "UTF-8")))))

;; Elle --------------------------------------------------------------------------------------

(defn elle-process
  "A process id for Elle: a driver takes a new one after an unknown outcome."
  []
  (ffi/elle-process-new))

(defn elle-note
  "A history line of type :invoke, :ok, :fail or :info for process, its micro-operations
  [[:append k v] [:r k nil-or-list]] (list-append) or [[:w k v] [:r k nil-or-value]]
  (rw-register), at this moment, for the check named check-name (:elle by default)."
  ([process type mops] (elle-note :elle process type mops))
  ([check-name process type mops]
   (alive!)
   (ffi/elle-note (name check-name) process (name type) mops)))

(defn elle-check
  "A host check: Elle on each timeline's history, its verdict asserted (Zig's sdk.elle.check).
  Options as its CheckOptions: :model (list-append, rw-register), :consistency, :by-scenario
  [{:scenario :consistency}], :allowed, :message, :realtime-reads."
  [options]
  (let [options-json (json/write-str options true)]
    ;; Its properties go in the program's catalog as it runs (`main`), as Zig's check has them:
    ;; only with the check. Nothing native as the namespace loads: it compiles anywhere.
    (with-meta (fn [{:keys [scenario history]}]
                 (ffi/elle-check scenario history options-json))
      {::elle-options options-json})))

(defn records
  "A check's history as data: its records, in order."
  [history]
  (into [] (comp (remove string/blank?) (map json/read-str)) (string/split-lines history)))

;; The program -------------------------------------------------------------------------------

(defn- present [m] (into {} (remove (comp nil? val)) m))

(defn- named [x] (if (keyword? x) (name x) x))

(defn definition
  "What det_describe takes: the program's definition as data, without its functions. Its custom
  faults are its node's (`<program> fault <name>`)."
  [{:keys [profiles node program scenarios checks custom-faults]}]
  {:profiles (for [profile profiles]
               (present
                (assoc profile
                       :nodes (for [[node-name spec] (:nodes profile)]
                                {:name (named node-name)
                                 :spec (present
                                        (cond-> spec
                                          (:after spec) (update :after #(mapv named %))
                                          (and (seq custom-faults) (= (named node-name) (named node)))
                                          (update-in [:faults :custom] (fnil into [])
                                                     (for [fault-name (sort (map named (keys custom-faults)))]
                                                       (str program " fault " fault-name)))))}))))
   :scenarios (for [scenario scenarios]
                (present
                 (assoc scenario
                        :node (some-> node named)
                        :program program
                        :commands (for [{:keys [kind] :as c} (:commands scenario)]
                                    {:kind kind :name (:name c)}))))
   :checks (map named (keys checks))})

(defn- scenario-of [program scenario-name]
  (or (first (filter #(= scenario-name (:name %)) (:scenarios program)))
      (throw (ex-info (str "no scenario " scenario-name) {:scenario scenario-name}))))

(defn- run [program scenario-name command-name]
  (let [scenario (scenario-of program scenario-name)
        command (or (first (filter #(= command-name (:name %)) (:commands scenario)))
                    (throw (ex-info (str "no command " command-name) {:command command-name})))
        resolved (system)]
    ((:run command) {:scenario scenario-name
                     :command command-name
                     :profile (or (:profile resolved) "default")})
    0))

(defn- declare-checks
  "The program's Elle checks' properties in its catalog (det_elle_declare), where it runs."
  [program]
  (doseq [[_ f] (:checks program)]
    (when-let [options (::elle-options (meta f))] (ffi/elle-declare options))))

(defn- compile-sources
  "Where the program runs, during the run's setup (`prepare` in its launcher, the node's command
  before the setup's snapshot): its namespaces compiled to /opt/workload/classes, first on the
  launcher's classpath for every command after. Compiling the program and determinismo.workload
  from source was most of a command's start: 3.2 s on a guest's vCPU, 1.1 s compiled, the JVM
  itself 20 ms."
  [main-ns]
  ;; Each namespace from the program's sources, its own file compiled (compile skips what is
  ;; loaded already, and they all are by now), the program's main last.
  (let [source? (fn [ns]
                  (let [path (-> (name (ns-name ns)) (string/replace "-" "_") (string/replace "." "/"))]
                    (.exists (java.io.File. (str "/opt/workload/src/" path ".clj")))))
        main (the-ns (symbol main-ns))]
    (binding [*compile-path* "/opt/workload/classes"]
      (doseq [ns (concat (remove #{main} (filter source? (all-ns))) [main])]
        (compile (ns-name ns)))))
  0)

(defn- custom-fault
  "One of the program's fault kinds, as the fault injector runs it (Faults.custom)."
  [program fault-name]
  (let [f (or (some (fn [[k f]] (when (= fault-name (named k)) f)) (:custom-faults program))
              (throw (ex-info (str "no custom fault " fault-name) {:fault fault-name})))
        resolved (system)]
    (f {:fault fault-name :profile (or (:profile resolved) "default")})
    0))

(defn- check [program check-name scenario-name]
  (let [f (or (some (fn [[k f]] (when (= check-name (named k)) f)) (:checks program))
              (throw (ex-info (str "no check " check-name) {:check check-name})))]
    (f {:scenario scenario-name :history (slurp *in*)})
    0))

(def commands-port
  "Where the client node's JVM takes the program's commands (`serve-commands`, loopback only):
  its launcher's `run` connects here (sdk/clojure/warm-run)."
  7889)

(def ^:private exit-mark
  "The line that ends a command's output on its connection, its status after it (a unit
  separator first: no output line starts so)."
  (str (char 31) "det-exit "))

(defn- command-start
  "One command a connection asks for (`run <scenario> <command>`), in a thread of its own, its
  output (*out*, *err*) on the connection, then its status; the connection's end before the
  command's is its client killed by the composer: the command's flag set, the thread
  interrupted (a blocking read ends), the command ending at its next call into the SDK."
  [program ^java.net.Socket socket]
  (let [in (.getInputStream socket)
        out (java.io.PrintWriter. (java.io.OutputStreamWriter. (.getOutputStream socket) "UTF-8") true)
        line (.readLine (java.io.BufferedReader. (java.io.InputStreamReader. in "UTF-8")))
        [verb scenario-name command-name] (string/split (or line "") #" ")
        killed (atom false)
        worker (Thread.
                ^Runnable
                (fn []
                  (let [status (binding [*killed* killed *out* out *err* out]
                                 (try
                                   (if (and (= verb "run") scenario-name command-name)
                                     (run program scenario-name command-name)
                                     (do (println "usage: run <scenario> <command>") 2))
                                   (catch Throwable t
                                     (when-not @killed (.printStackTrace t out))
                                     1)))]
                    (try (.print out (str exit-mark status "\n")) (.flush out) (.close socket)
                         (catch Exception _ nil))))
                (str "det-command " command-name))]
    (.start worker)
    (doto (Thread. ^Runnable
                   (fn []
                     (try (while (not= -1 (.read in))) (catch Exception _ nil))
                     (when (.isAlive worker)
                       (reset! killed true)
                       (.interrupt worker)))
                   (str "det-command-watch " command-name))
      (.setDaemon true)
      (.start))))

(defn- serve-commands
  "The program's commands taken on 127.0.0.1:commands-port, each in this JVM: no JVM started and
  no library loaded again for a command (Datalevin's drivers spent a median 4.4 s of each start
  loading, 270 s of a timeline's drive phase: PLAN.md's warm runner)."
  [program]
  (let [server (java.net.ServerSocket. (int commands-port) 64 (java.net.InetAddress/getLoopbackAddress))]
    (doto (Thread. ^Runnable
                   (fn [] (loop [] (command-start program (.accept server)) (recur)))
                   "det-commands")
      (.setDaemon true)
      (.start))
    (println (str "commands: listening on 127.0.0.1:" commands-port))))

(defn- nrepl
  "An nREPL server on bind:port (127.0.0.1 unless given) with CIDER's middleware, the program
  loaded, until killed: a REPL inside the guest, where the system runs (its nodes by name), the
  program's commands and libdeterminismo at hand. From outside through a session
  (infra/host/nrepl-proxy.py). As a node's command, ready on its port (bind 0.0.0.0: the runner
  checks it from outside the node), it is up before the setup's snapshot: warm in every session.
  The program's commands are taken too (`serve-commands`), before the REPL listens: the node is
  ready once both are. Needs nREPL and cider-nrepl on the classpath (the client image's
  deps.edn)."
  [program port bind]
  (let [start-server (requiring-resolve 'nrepl.server/start-server)
        handler @(requiring-resolve 'cider.nrepl/cider-nrepl-handler)]
    (declare-checks program)
    ;; The program's own warm-up first (its clients opened, say), in the setup's snapshot.
    (when-let [warm (:warm program)] (warm))
    (serve-commands program)
    (start-server :bind bind :port port :handler handler)
    (println "nrepl: listening on" (str bind ":" port))
    @(promise)))

(defn main
  "--describe on the host; run <scenario> <command> where the program runs; check <name>
  <scenario> on the host; fault <name> where the program runs, as the fault injector asks;
  nrepl <port> [bind] where the program runs, for a REPL; compile <main ns> where it runs, during
  setup (its launcher's prepare). Exits with its status."
  [program arguments]
  (let [[verb a b] arguments
        status (try
                 (cond
                   (= ["--describe"] (vec arguments))
                   (do (ffi/describe (json/write-str (definition program) true)) 0)
                   (and (= verb "nrepl") a (<= 2 (count arguments) 3)) (nrepl program (parse-long a) (or b "127.0.0.1"))
                   (and (= verb "run") a b (= 3 (count arguments))) (do (declare-checks program) (run program a b))
                   (and (= verb "compile") a (= 2 (count arguments))) (compile-sources a)
                   (and (= verb "check") a b (= 3 (count arguments))) (check program a b)
                   (and (= verb "fault") a (= 2 (count arguments))) (custom-fault program a)
                   :else (do (binding [*out* *err*]
                               (println "usage: --describe | run <scenario> <command> | check <name> <scenario> | fault <name> | nrepl <port> [bind] | compile <main ns>"))
                             2))
                 (catch Throwable t
                   (.printStackTrace t)
                   1))]
    (flush)
    (System/exit status)))
