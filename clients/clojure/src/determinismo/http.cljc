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

// method url body path -> the status: curl, the answer's bytes written to `path` as they are.
long determinismo_download(std::string const &url, std::string const &body, std::string const &path) {
  char request[] = \"/tmp/determinismo-http-XXXXXX\";
  int fd = mkstemp(request);
  if (fd < 0) return 0;
  if (!body.empty()) (void)!write(fd, body.data(), body.size());
  close(fd);
  std::string command = \"curl -s -m 3600 -o '\" + path + \"' -w '%{http_code}' -X POST\";
  if (!body.empty()) command += std::string(\" -H 'content-type: application/json' --data-binary @\") + request;
  command += \" '\" + url + \"'\";
  std::string out;
  if (FILE *pipe = popen(command.c_str(), \"r\")) {
    std::array<char, 64> buffer;
    size_t n;
    while ((n = fread(buffer.data(), 1, buffer.size(), pipe)) > 0) out.append(buffer.data(), n);
    pclose(pipe);
  }
  unlink(request);
  return out.empty() ? 0 : std::stol(out);
}

// bytes -> base64 (standard, padded).
std::string determinismo_base64(std::string const &bytes) {
  static char const table[] = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";
  std::string out;
  size_t i = 0;
  for (; i + 2 < bytes.size(); i += 3) {
    unsigned n = ((unsigned char)bytes[i] << 16) | ((unsigned char)bytes[i + 1] << 8) | (unsigned char)bytes[i + 2];
    out += table[n >> 18]; out += table[(n >> 12) & 63]; out += table[(n >> 6) & 63]; out += table[n & 63];
  }
  if (i + 1 == bytes.size()) {
    unsigned n = (unsigned char)bytes[i] << 16;
    out += table[n >> 18]; out += table[(n >> 12) & 63]; out += \"==\";
  } else if (i + 2 == bytes.size()) {
    unsigned n = ((unsigned char)bytes[i] << 16) | ((unsigned char)bytes[i + 1] << 8);
    out += table[n >> 18]; out += table[(n >> 12) & 63]; out += table[(n >> 6) & 63]; out += '=';
  }
  return out;
}

// A local file's bytes in base64; \"\" when it cannot be read.
std::string determinismo_file_base64(std::string const &path) {
  FILE *file = fopen(path.c_str(), \"rb\");
  if (!file) return std::string();
  std::string bytes;
  std::array<char, 65536> buffer;
  size_t n;
  while ((n = fread(buffer.data(), 1, buffer.size(), file)) > 0) bytes.append(buffer.data(), n);
  fclose(file);
  return determinismo_base64(bytes);
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

(defn download
  "POSTs `body` (a string) to `url` and writes the answer's bytes to the local file `path`, as
  they are: [status path]."
  [url body path]
  #?(:clj
     (let [client (java.net.http.HttpClient/newHttpClient)
           built (-> (java.net.http.HttpRequest/newBuilder (java.net.URI/create url))
                     (.header "content-type" "application/json")
                     (.POST (java.net.http.HttpRequest$BodyPublishers/ofString body))
                     (.build))
           response (.send client built (java.net.http.HttpResponse$BodyHandlers/ofFile
                                         (.toPath (java.io.File. ^String path))))]
       [(.statusCode response) path])
     :jank
     [(long (cpp/determinismo_download (cpp/cast cpp/std.string url) (cpp/cast cpp/std.string body)
                                       (cpp/cast cpp/std.string path)))
      path]))

(defn file-base64
  "A local file's bytes in base64 (standard, padded)."
  [path]
  #?(:clj (.encodeToString (java.util.Base64/getEncoder)
                           (java.nio.file.Files/readAllBytes (.toPath (java.io.File. ^String path))))
     :jank (let [encoded (str (cpp/determinismo_file_base64 (cpp/cast cpp/std.string path)))]
             (when (= "" encoded) (throw (ex-info (str "cannot read " path) {:path path})))
             encoded)))

(defn text-base64
  "A string's bytes (UTF-8) in base64 (standard, padded)."
  [text]
  #?(:clj (.encodeToString (java.util.Base64/getEncoder) (.getBytes ^String text "UTF-8"))
     :jank (str (cpp/determinismo_base64 (cpp/cast cpp/std.string text)))))

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
