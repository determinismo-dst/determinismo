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
;;
;; A strategy's functions, each optional (missing: the explorer's own answer):
;;   :returns (fn [generation candidates count]) -> [{:branch :vtime_ns :reason [:branches]}] or
;;            {:returns [...] :fill "fresh"|"explorer"}: where the tree branches next
;;   :event   (fn [state request]) -> end-timeline to end the timeline there, else anything
;;   :decide  (fn [state request]) -> {:hex "<bytes>"} to answer a randomness pull, nil the default
;;   :branch  (fn [state request]) and :end (fn [state request]): a timeline's start and end
;; :wants (["behaviors"], ["labeled"], ...) and :decide make the hello's answer. `state` is an atom
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
std::string determinismo_close(std::string const &fd_text) {
  int fd = (int)std::stol(fd_text);
  { std::lock_guard<std::mutex> hold(determinismo_lines_lock); determinismo_lines.erase(fd); }
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
          :vtime_ns (+ (:start_ns candidate) (quot (- (:end_ns candidate) (:start_ns candidate)) 2))
          :reason (str "middle of timeline " (:branch candidate))})))

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

(defn answer
  "A request's reply (docs/PLUGINS.md's messages), `{}` for the default."
  [request state]
  (swap! requests inc)
  (let [method (:method request)
        chosen (strategy)]
    (cond
      (= method "hello")
      {:name (str #?(:jank "jank/" :default "clojure/") (name @current)) :decides (boolean (:decide chosen))
       :wants (or (:wants chosen) ["behaviors"])}
      (= method "branch")
      (do (reset! state {})
          (when-let [f (:branch chosen)] (f state request))
          {})
      (= method "event")
      (let [f (:event chosen)]
        (if (and f (= end-timeline (f state request))) {:end true} {}))
      (= method "events")
      (let [f (:event chosen)
            ended (when f (some (fn [e] (= end-timeline (f state (assoc e :method "event")))) (:events request)))]
        (if ended {:end true} {}))
      (= method "random")
      (or (when-let [f (:decide chosen)] (f state request)) {})
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

     ;; One connection: its lines answered until it closes. Every loop here has a way out: jank 0.1
     ;; cannot compile a loop whose every path recurs ("'break' statement not in loop", 2026-11-18).
     (defn- serve-connection [connection]
       (let [state (atom {})]
         (loop [answered 0]
           (let [line (str (cpp/determinismo_read_line (as-text connection)))]
             (if (= line "\n")
               (cpp/determinismo_close (as-text connection))
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
