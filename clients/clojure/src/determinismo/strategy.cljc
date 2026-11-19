;; SPDX-License-Identifier: MIT
;; Exploration strategies served from a REPL (docs/PLUGINS.md, protocol v1), the JVM's, babashka's
;; and jank's alike: a strategy is a map of functions, the registry is live, and the next request
;; uses what the REPL defined last. No rebuild, no restart.
;;
;;   (require '[determinismo.strategy :as strategy])
;;   (strategy/serve! 9120)                  ; then: determinismo explore ... --strategy tcp://127.0.0.1:9120
;;   (strategy/use-strategy! :middle)        ; the next generation's returns are its
;;   (swap! strategy/strategies assoc :mine {:returns (fn [generation candidates n] ...)})
;;   @strategy/generations                   ; what each generation offered and what was chosen
;;   (strategy/use-strategy-for! "redis-server" :mine) ; that process's decisions and events: :mine's
;;
;; A strategy's functions, each optional (missing: the explorer's own answer):
;;   :returns (fn [generation candidates count]) -> [{:branch :vtime_ns :reason [:branches]}] or
;;            {:returns [...] :fill "fresh"|"explorer"}: where the tree branches next
;;   :event   (fn [state request]) -> end-timeline to end the timeline there, else anything
;;   :decide  (fn [state request]) -> {:hex "<bytes>"} to answer a randomness pull, nil the default
;;   :branch  (fn [state request]) and :end (fn [state request]): a timeline's start and end;
;;            :branch may return {:seed "<16 hex digits>"}: the timeline's seed instead
;;   :machine (fn [request]) -> the machine the run boots, before it does: {:epoch_seconds ...
;;            :timer_slack_us ... :tsc_jitter_seed "<hex>" :modulation_stretch_us [low high]}, any
;;            of them (docs/PLUGINS.md's machine)
;;   :check   (fn [state request]) -> a timeline that ended, judged from the events it was told:
;;            [{:type "always" :message "..." :condition bool :details {...}} ...], the
;;            timeline's assertions (docs/PLUGINS.md's check); (:histories request) has what the
;;            timeline recorded for the program's host checks ([{:name :records} ...], JSON
;;            lines); with :wants ["plans"] it is never asked for a decision
;; :wants (["behaviors"], ["labeled"], ["setup"]: the setup's decisions too, ...) and :decide make
;; the hello's answer. `state` is an atom
;; per connection: one exploration worker's timelines, reset at each branch. Every answer a
;; strategy gives is on the timeline's tape, so the timeline replays without it.
(ns determinismo.strategy
  (:require [clojure.string :as str]
            [determinismo.json :as json]))

#?(:jank
   (cpp/raw "
#include <arpa/inet.h>
#include <mutex>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <unordered_map>
#ifdef __linux__
#include <atomic>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <linux/futex.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#endif
// Strings across the boundary (numbers as their decimal text): jank calls these as the HTTP
// client's are called. A listening TCP socket on 127.0.0.1:port, or -1.
std::string determinismo_listen(std::string const &port_text) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return \"-1\";
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons((unsigned short)std::stol(port_text));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (sockaddr *)&address, sizeof address) < 0 || listen(fd, 64) < 0) { close(fd); return \"-1\"; }
  return std::to_string(fd);
}
std::string determinismo_accept(std::string const &fd_text) {
  return std::to_string(accept((int)std::stol(fd_text), nullptr, nullptr));
}
// Each connection's bytes read past its last line.
static std::mutex determinismo_lines_lock;
static std::unordered_map<int, std::string> determinismo_lines;
// The connection's next line (its newline left out); a lone newline once it has ended.
std::string determinismo_read_line(std::string const &fd_text) {
  int fd = (int)std::stol(fd_text);
  std::string pending;
  { std::lock_guard<std::mutex> hold(determinismo_lines_lock); pending.swap(determinismo_lines[fd]); }
  while (true) {
    size_t cut = pending.find('\\n');
    if (cut != std::string::npos) {
      std::string line = pending.substr(0, cut);
      std::lock_guard<std::mutex> hold(determinismo_lines_lock);
      determinismo_lines[fd] = pending.substr(cut + 1);
      return line;
    }
    char buffer[65536];
    ssize_t n = read(fd, buffer, sizeof buffer);
    if (n <= 0) return std::string(\"\\n\");
    pending.append(buffer, (size_t)n);
  }
}
std::string determinismo_write_line(std::string const &fd_text, std::string const &line) {
  int fd = (int)std::stol(fd_text);
  std::string out = line + \"\\n\";
  size_t done = 0;
  while (done < out.size()) {
    ssize_t n = write(fd, out.data() + done, out.size() - done);
    if (n <= 0) return \"0\";
    done += (size_t)n;
  }
  return \"1\";
}
// The ring (docs/PLUGINS.md): a connection's calls through the explorer's shared mapping, a
// futex word flipped each way (its header: magic at 0, state at 8, request_size at 12,
// reply_size at 16). Linux only: elsewhere a hello does not ask for one.
struct determinismo_ring { char *memory; size_t size, request_at, reply_at, reply_max; };
static std::unordered_map<int, determinismo_ring> determinismo_rings;
std::string determinismo_ring_supported() {
#ifdef __linux__
  return \"1\";
#else
  return \"0\";
#endif
}
// Maps the explorer's ring for a connection: \"1\" when taken.
std::string determinismo_ring_open(std::string const &fd_text, std::string const &path, std::string const &size_text,
                                   std::string const &request_at_text, std::string const &reply_at_text,
                                   std::string const &reply_max_text) {
#ifdef __linux__
  int fd = (int)std::stol(fd_text);
  size_t size = std::stoull(size_text);
  int file = open(path.c_str(), O_RDWR | O_CLOEXEC);
  if (file < 0) return \"0\";
  void *mapped = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
  close(file);
  if (mapped == MAP_FAILED) return \"0\";
  if (memcmp(mapped, \"DETRING1\", 8) != 0) { munmap(mapped, size); return \"0\"; }
  std::lock_guard<std::mutex> hold(determinismo_lines_lock);
  determinismo_rings[fd] = {(char *)mapped, size, std::stoull(request_at_text), std::stoull(reply_at_text),
                            std::stoull(reply_max_text)};
  return \"1\";
#else
  return \"0\";
#endif
}
#ifdef __linux__
static determinismo_ring determinismo_ring_of(int fd) {
  std::lock_guard<std::mutex> hold(determinismo_lines_lock);
  return determinismo_rings.at(fd);
}
static std::atomic<uint32_t> *determinismo_ring_state(char *memory) {
  return reinterpret_cast<std::atomic<uint32_t> *>(memory + 8);
}
#endif
// The connection's next request through its ring (spinning a little, then sleeping on the
// word); a lone newline once its socket has ended.
std::string determinismo_ring_next(std::string const &fd_text) {
#ifdef __linux__
  int fd = (int)std::stol(fd_text);
  determinismo_ring ring = determinismo_ring_of(fd);
  std::atomic<uint32_t> *state = determinismo_ring_state(ring.memory);
  for (unsigned spins = 0;;) {
    uint32_t seen = state->load(std::memory_order_acquire);
    if (seen == 1) {
      uint32_t size;
      memcpy(&size, ring.memory + 12, 4);
      return std::string(ring.memory + ring.request_at, size);
    }
    if (spins < 4096) {
      spins++;
#if defined(__x86_64__)
      __builtin_ia32_pause();
#endif
      continue;
    }
    timespec timeout{0, 10 * 1000 * 1000};
    syscall(SYS_futex, (uint32_t *)state, FUTEX_WAIT, seen, &timeout, nullptr, 0);
    pollfd polled{fd, (short)(POLLIN | POLLRDHUP), 0};
    if (poll(&polled, 1, 0) == 1 && (polled.revents & (POLLHUP | POLLRDHUP | POLLERR))) return std::string(\"\\n\");
  }
#else
  return std::string(\"\\n\");
#endif
}
// A request's reply into the ring, the explorer woken: \"0\" for one past its room ({} instead).
std::string determinismo_ring_reply(std::string const &fd_text, std::string const &reply) {
#ifdef __linux__
  int fd = (int)std::stol(fd_text);
  determinismo_ring ring = determinismo_ring_of(fd);
  bool fits = reply.size() <= ring.reply_max;
  std::string const &out = fits ? reply : std::string(\"{}\");
  memcpy(ring.memory + ring.reply_at, out.data(), out.size());
  uint32_t size = (uint32_t)out.size();
  memcpy(ring.memory + 16, &size, 4);
  std::atomic<uint32_t> *state = determinismo_ring_state(ring.memory);
  state->store(2, std::memory_order_release);
  syscall(SYS_futex, (uint32_t *)state, FUTEX_WAKE, 1, nullptr, nullptr, 0);
  return fits ? \"1\" : \"0\";
#else
  return \"0\";
#endif
}
std::string determinismo_close(std::string const &fd_text) {
  int fd = (int)std::stol(fd_text);
  {
    std::lock_guard<std::mutex> hold(determinismo_lines_lock);
    determinismo_lines.erase(fd);
#ifdef __linux__
    auto found = determinismo_rings.find(fd);
    if (found != determinismo_rings.end()) {
      munmap(found->second.memory, found->second.size);
      determinismo_rings.erase(found);
    }
#endif
  }
  close(fd);
  return \"0\";
}
"))

;; An :event function's answer that ends the timeline at that event.
(def end-timeline ::end)

(defn- middle
  "Each of the first `n` candidates by the behaviors they reached first, branched from the middle
  of its span: a strategy short enough to read, to start a new one from."
  [_generation candidates n]
  (vec (for [candidate (take n (sort-by (fn [c] (- (or (:novel c) 0))) candidates))]
         {:branch (:branch candidate)
          ;; +' and -': exact past 2^31 under jank 0.1 too (its + wraps at 32 bits when both
          ;; operands fit them), a long on the JVM as +.
          :vtime_ns (+' (:start_ns candidate) (quot (-' (:end_ns candidate) (:start_ns candidate)) 2))
          :reason (str "middle of timeline " (:branch candidate))})))

;; Whether this host takes a connection's calls through the explorer's shared mapping (a ring:
;; jank's on Linux), which its hello then asks for.
(def ^:private ring-supported?
  #?(:jank (= "1" (str (cpp/determinismo_ring_supported))) :default false))

(defonce strategies
  (atom {:explorer {}
         :middle {:returns middle}}))

(defonce current (atom :explorer))

;; What the strategies saw, for the REPL: the last 64 generations (candidates and choices) and
;; each timeline's end.
(defonce generations (atom []))
(defonce ends (atom {}))
(defonce requests (atom 0))

(defn use-strategy!
  "The strategy every connection answers with from its next request."
  [name]
  (when-not (contains? @strategies name)
    (throw (ex-info (str "determinismo: no strategy " name) {:name name :known (keys @strategies)})))
  (reset! current name)
  name)

(defn- strategy [] (get @strategies @current))

;; Per service: which strategy answers the decisions and events of a source (the asking
;; process's name, as requests say it), as [matcher name] pairs, the first match answering; the
;; run-wide one (`use-strategy!`) answers the rest, and always a generation's returns.
(defonce by-source (atom []))

(defn use-strategy-for!
  "The strategy that answers the decisions and events whose source (the asking process's name)
  is `source`, a string, or a regex found in it, from each connection's next timeline (its
  hello says what it decides); `name` nil: the run-wide one again."
  [source name]
  (when (and name (not (contains? @strategies name)))
    (throw (ex-info (str "determinismo: no strategy " name) {:name name :known (keys @strategies)})))
  (let [kept (vec (remove (fn [[matcher _]] (= (str matcher) (str source))) @by-source))]
    (reset! by-source (if name (conj kept [source name]) kept))
    name))

(defn- matches? [matcher source]
  (if (string? matcher) (= matcher source) (boolean (re-find matcher (str source)))))

(defn- strategy-for
  "The strategy answering a decision or an event from `source`."
  [source]
  (or (some (fn [[matcher name]] (when (matches? matcher source) (get @strategies name))) @by-source)
      (strategy)))

(defn- every-strategy
  "The run-wide strategy and every per-source one: what a hello says for all of them."
  []
  (cons (strategy) (keep (fn [[_ name]] (get @strategies name)) @by-source)))

(defn answer
  "A request's reply (docs/PLUGINS.md's messages), `{}` for the default."
  [request state]
  (swap! requests inc)
  (let [method (:method request)
        chosen (strategy)]
    (cond
      (= method "hello")
      (let [all (every-strategy)]
        {:name (str #?(:jank "jank/" :default "clojure/") (name @current)
                    (when (seq @by-source) (str " +" (count @by-source) " per source")))
         ;; A checker is told the timeline's events: it is in the timelines as a decider is.
         :decides (boolean (some #(or (:decide %) (:check %)) all))
         :wants (vec (distinct (concat (mapcat (fn [one] (or (:wants one) ["behaviors"])) all)
                                       (when (some :machine all) ["machine"])
                                       (when (some :check all) ["check"]))))
         :ring ring-supported?})
      (= method "branch")
      ;; A :branch function may give the timeline another seed: {:seed "<16 hex digits>"}.
      (do (reset! state {})
          (let [given (when-let [f (:branch chosen)] (f state request))]
            (if (and (map? given) (string? (:seed given))) {:seed (:seed given)} {})))
      (= method "event")
      (let [f (:event (strategy-for (:source request)))]
        (if (and f (= end-timeline (f state request))) {:end true} {}))
      (= method "events")
      (let [ended (some (fn [e] (let [f (:event (strategy-for (:source e)))]
                                  (and f (= end-timeline (f state (assoc e :method "event"))))))
                        (:events request))]
        (if ended {:end true} {}))
      (= method "machine")
      (or (when-let [f (:machine chosen)] (f request)) {})
      (= method "check")
      {:assertions (vec (or (when-let [f (:check chosen)] (f state request)) []))}
      (= method "random")
      (or (when-let [f (:decide (strategy-for (:source request)))] (f state request)) {})
      (= method "branch_end")
      (do (swap! ends assoc (:index request) (select-keys request [:outcome :events :failing]))
          (when-let [f (:end chosen)] (f state request))
          {})
      (= method "returns")
      (let [f (:returns chosen)
            given (when f (f (:generation request) (:candidates request) (:count request)))
            fill (when (map? given) (:fill given))
            chosen-returns (vec (if (map? given) (:returns given) given))]
        (swap! generations (fn [kept] (conj (if (>= (count kept) 64) (vec (rest kept)) kept)
                                            {:generation (:generation request) :strategy @current
                                             :candidates (:candidates request) :chosen chosen-returns})))
        (cond-> (if (seq chosen-returns)
                  {:returns (mapv (fn [r] (select-keys r [:branch :vtime_ns :reason :horizon_ns :branches])) chosen-returns)}
                  {})
          fill (assoc :fill fill)))
      :else {})))

(defn- answer-line
  "A request line's reply line: one that fails is answered {} (the explorer goes on with its own
  choices; a connection closed on an error failed its worker), the error said on stderr."
  [line state]
  (json/write-json
   (try (answer (json/read-json line) state)
        (catch #?(:clj Throwable :jank jank.runtime.object_ref) e
          (binding [*out* *err*] (println "determinismo strategy: answer failed:" (subs line 0 (min 80 (count line))) (str e)))
          {})
        #?@(:jank [(catch cpp/std.exception e
                     (binding [*out* *err*] (println "determinismo strategy: answer failed:" (subs line 0 (min 80 (count line))) (cpp/.what e)))
                     {})]))))

#?(:jank
   (do
     (defn- as-text [x] (cpp/cast cpp/std.string (str x)))

     ;; A connection's calls through its ring once the explorer gave it one, until its socket
     ;; ends: how many.
     (defn- serve-ring [connection state]
       (loop [answered 0]
         (let [line (str (cpp/determinismo_ring_next (as-text connection)))]
           (if (= line "\n")
             answered
             (do (cpp/determinismo_ring_reply (as-text connection) (cpp/cast cpp/std.string (answer-line line state)))
                 (recur (inc answered)))))))

     ;; The explorer's offer of a ring: taken when it maps, said over the socket; true if taken.
     (defn- take-ring [connection line]
       (let [offer (json/read-json line)
             taken (= "1" (str (cpp/determinismo_ring_open (as-text connection) (as-text (:path offer)) (as-text (:size offer))
                                                           (as-text (:request_at offer)) (as-text (:reply_at offer))
                                                           (as-text (:reply_max offer)))))]
         (cpp/determinismo_write_line (as-text connection) (cpp/cast cpp/std.string (json/write-json {:ring taken})))
         taken))

     ;; One connection: its lines answered until it closes, or its ring's calls once it has one.
     ;; Every loop here has a way out: jank 0.1 cannot compile a loop whose every path recurs
     ;; ("'break' statement not in loop", 2026-11-18).
     (defn- serve-connection [connection]
       (let [state (atom {})]
         (loop [answered 0]
           (let [line (str (cpp/determinismo_read_line (as-text connection)))]
             (cond
               (= line "\n") (cpp/determinismo_close (as-text connection))
               (str/starts-with? line "{\"method\":\"ring\"")
               (do (when (take-ring connection line) (serve-ring connection state))
                   (cpp/determinismo_close (as-text connection)))
               :else
               (do (cpp/determinismo_write_line (as-text connection) (cpp/cast cpp/std.string (answer-line line state)))
                   (recur (inc answered))))))))

     ;; Connections accepted until the listening socket is closed: how many.
     (defn- accept-loop [fd]
       (loop [accepted 0]
         (let [connection (parse-long (str (cpp/determinismo_accept (as-text fd))))]
           (if (neg? connection)
             accepted
             (do (future (serve-connection connection))
                 (recur (inc accepted)))))))))

(defn serve!
  "Serves the protocol on 127.0.0.1:`port` (a connection a worker, each on its own thread), the
  registry's current strategy answering. -> the listening socket (the JVM's) or its descriptor."
  [port]
  #?(:clj
     (let [server (java.net.ServerSocket. (int port) 64 (java.net.InetAddress/getByName "127.0.0.1"))]
       (future
         (loop []
           (let [socket (.accept server)]
             (future
               (let [state (atom {})]
                 (with-open [socket socket
                             reader (java.io.BufferedReader. (java.io.InputStreamReader. (.getInputStream socket) "UTF-8"))
                             writer (java.io.BufferedWriter. (java.io.OutputStreamWriter. (.getOutputStream socket) "UTF-8"))]
                   (loop []
                     (when-let [line (.readLine reader)]
                       (.write writer (str (answer-line line state) "\n"))
                       (.flush writer)
                       (recur)))))))
           (recur)))
       server)
     :jank
     (let [fd (parse-long (str (cpp/determinismo_listen (as-text port))))]
       (when (neg? fd)
         (throw (ex-info (str "determinismo: cannot listen on 127.0.0.1:" port) {:port port})))
       (future (accept-loop fd))
       fd)))
