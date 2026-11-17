;; SPDX-License-Identifier: MIT
;; HTTP to serve, with nothing to install: java.net.http on the JVM and in babashka, curl through
;; C++ on jank. One function: a method, a URL, a body (or nil), the answer's [status body].
(ns determinismo.http
  (:require [clojure.string :as str]))

#?(:jank
   (cpp/raw "
#include <array>
#include <chrono>
#include <cstdio>
#include <thread>
#include <cstdlib>
#include <string>
#include <unistd.h>

// method url body -> \"<status>\\n<body>\": curl, the body from a temporary file (no quoting).
std::string determinismo_http(std::string const &method, std::string const &url, std::string const &body) {
  char path[] = \"/tmp/determinismo-http-XXXXXX\";
  int fd = mkstemp(path);
  if (fd < 0) return \"0\\n\";
  if (!body.empty()) (void)!write(fd, body.data(), body.size());
  close(fd);
  std::string command = \"curl -s -m 3600 -o - -w '\\\\n%{http_code}' -X \" + method;
  if (!body.empty()) command += std::string(\" -H 'content-type: application/json' --data-binary @\") + path;
  command += \" '\" + url + \"'\";
  std::string out;
  if (FILE *pipe = popen(command.c_str(), \"r\")) {
    std::array<char, 65536> buffer;
    size_t n;
    while ((n = fread(buffer.data(), 1, buffer.size(), pipe)) > 0) out.append(buffer.data(), n);
    pclose(pipe);
  }
  unlink(path);
  size_t cut = out.rfind('\\n');
  if (cut == std::string::npos) return \"0\\n\" + out;
  return out.substr(cut + 1) + \"\\n\" + out.substr(0, cut);
}

void determinismo_sleep_ms(long ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

std::string determinismo_getenv(std::string const &name) {
  char const *value = std::getenv(name.c_str());
  return value ? std::string(value) : std::string();
}
"))

(defn request
  "[status body] for `method` (:get, :post) at `url`, with `body` (a string) or nil."
  [method url body]
  #?(:clj
     (let [client (java.net.http.HttpClient/newHttpClient)
           builder (-> (java.net.http.HttpRequest/newBuilder (java.net.URI/create url))
                       (.header "content-type" "application/json"))
           publisher (if body
                       (java.net.http.HttpRequest$BodyPublishers/ofString body)
                       (java.net.http.HttpRequest$BodyPublishers/noBody))
           built (.build (.method builder (str/upper-case (name method)) publisher))
           response (.send client built (java.net.http.HttpResponse$BodyHandlers/ofString))]
       [(.statusCode response) (.body response)])
     :jank
     (let [answer (str (cpp/determinismo_http (cpp/cast cpp/std.string (str/upper-case (name method)))
                                              (cpp/cast cpp/std.string url)
                                              (cpp/cast cpp/std.string (or body ""))))
           cut (str/index-of answer "\n")]
       [(parse-long (subs answer 0 cut)) (subs answer (inc cut))])))

(defn sleep-ms [ms]
  #?(:clj (Thread/sleep (long ms))
     :jank (cpp/determinismo_sleep_ms (cpp/cast cpp/long ms))))

(defn env
  "The environment variable `name`, or nil."
  [name]
  #?(:clj (System/getenv name)
     :jank (let [value (str (cpp/determinismo_getenv (cpp/cast cpp/std.string name)))]
             (when-not (= "" value) value))))

(def url
  "serve's address: $DETERMINISMO_URL, else http://127.0.0.1:7878."
  (or (env "DETERMINISMO_URL") "http://127.0.0.1:7878"))
