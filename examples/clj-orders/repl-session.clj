;; SPDX-License-Identifier: MIT
;; The orders service, written at the REPL in a fast VM (README.md): evaluated form by form.
(require '[next.jdbc :as jdbc]
         '[determinismo.workload :as w])
(import '[org.apache.kafka.clients.producer KafkaProducer ProducerRecord]
        '[org.apache.kafka.clients.consumer KafkaConsumer]
        '[com.sun.net.httpserver HttpServer HttpHandler HttpExchange]
        '[java.net InetSocketAddress]
        '[java.time Duration])

(def db {:dbtype "postgresql" :host "postgres" :dbname "postgres" :user "postgres"})
(jdbc/execute! db ["CREATE TABLE IF NOT EXISTS orders (id text PRIMARY KEY, item text NOT NULL)"])

(def kafka-props {"bootstrap.servers" "kafka:9092"
                  "key.serializer" "org.apache.kafka.common.serialization.StringSerializer"
                  "value.serializer" "org.apache.kafka.common.serialization.StringSerializer"
                  "acks" "all" "enable.idempotence" "true"})
(def producer (KafkaProducer. ^java.util.Map kafka-props))

(defn place! [item]
  ;; Acknowledged once Kafka has it (acks=all): the order's id.
  (let [id (str (random-uuid))]
    (.get (.send producer (ProducerRecord. "orders" id item)))
    id))

(def consumer-props {"bootstrap.servers" "kafka:9092" "group.id" "orders-writer"
                     "key.deserializer" "org.apache.kafka.common.serialization.StringDeserializer"
                     "value.deserializer" "org.apache.kafka.common.serialization.StringDeserializer"
                     "auto.offset.reset" "earliest" "enable.auto.commit" "false"})

(defn consume! []
  ;; Each order into Postgres, then its offset committed: at least once, inserted once.
  (with-open [consumer (KafkaConsumer. ^java.util.Map consumer-props)]
    (.subscribe consumer ["orders"])
    (loop []
      (let [records (.poll consumer (Duration/ofMillis 500))]
        (doseq [record records]
          (jdbc/execute! db ["INSERT INTO orders (id, item) VALUES (?, ?) ON CONFLICT (id) DO NOTHING"
                             (.key record) (.value record)]))
        (.commitSync consumer))
      (recur))))

(def consumer-thread (doto (Thread. ^Runnable (fn [] (try (consume!) (catch Throwable t (println "consumer:" t))))) .start))

(defn respond [^HttpExchange exchange status ^String body]
  (let [bytes (.getBytes body)]
    (.sendResponseHeaders exchange status (alength bytes))
    (with-open [out (.getResponseBody exchange)] (.write out bytes))))

(defn verify [ids]
  ;; Every acknowledged order in Postgres within 60 s: one query a try.
  (let [deadline (+ (System/currentTimeMillis) 60000)
        wanted (set ids)]
    (loop []
      (let [present (set (map :orders/id (jdbc/execute! db ["SELECT id FROM orders WHERE id = ANY(?)" (into-array String wanted)])))
            missing (remove present wanted)]
        (if (or (empty? missing) (> (System/currentTimeMillis) deadline))
          (do (w/always (empty? missing) "every acknowledged order is in Postgres"
                        {:acknowledged (count wanted) :missing (count missing) :example (first missing)})
              (str (count missing) " missing of " (count wanted)))
          (do (Thread/sleep 500) (recur)))))))

(def server
  (doto (HttpServer/create (InetSocketAddress. 8080) 64)
    (.createContext "/orders" (reify HttpHandler
                                (handle [_ exchange]
                                  (try (respond exchange 200 (place! (slurp (.getRequestBody exchange))))
                                       (catch Exception e (respond exchange 503 (str e)))))))
    (.createContext "/verify" (reify HttpHandler
                                (handle [_ exchange]
                                  (let [ids (remove empty? (clojure.string/split-lines (slurp (.getRequestBody exchange))))]
                                    (respond exchange 200 (verify ids))))))
    (.setExecutor (java.util.concurrent.Executors/newFixedThreadPool 8))
    (.start)))

;; Try it here, at full speed.
(place! "first-book")
(Thread/sleep 2000)
(jdbc/execute! db ["SELECT count(*) FROM orders"])

;; Then explore from this machine as it stands: timelines with faults (Kafka and Postgres
;; crashed, the network cut), the drivers in the image placing orders against this service.
(w/explore-here! {:branches 24 :time-budget "10m"})

;; What the timelines found (run 1, 13 of 24 timelines failing):
;; - one exception left consume!, its thread ended, and no order after it reached Postgres
;;   (9 timelines): a Postgres connection failing under a fault (6), Kafka's commitSync timing
;;   out (2), the consumer kicked out of its group (1);
;; - a consumer alive but slow: a connection opened per insert (10.8 ms each here, 3.0 ms on
;;   one kept open), about 90 orders a second, behind by thousands when the faults stopped
;;   (4 timelines: the most orders acknowledged).
;; The fix, here: the consumer reopens after an error, and writes each poll's orders in one
;; batch, one transaction, on a connection it keeps (offsets committed after: at least once,
;; stored once).
(def running (atom true))

(defn consume! []
  (while @running
    (try
      (with-open [consumer (KafkaConsumer. ^java.util.Map consumer-props)
                  connection (jdbc/get-connection db)]
        (.subscribe consumer ["orders"])
        (while @running
          (let [records (.poll consumer (Duration/ofMillis 500))]
            (when-not (.isEmpty records)
              (jdbc/with-transaction [tx connection]
                (with-open [statement (jdbc/prepare tx ["INSERT INTO orders (id, item) VALUES (?, ?) ON CONFLICT (id) DO NOTHING"])]
                  (jdbc/execute-batch! statement (mapv (fn [record] [(.key record) (.value record)]) records)))))
            (.commitSync consumer))))
      (catch Exception e
        (println "consumer, reopening:" (.getMessage e))
        (Thread/sleep 1000)))))

(defn verify [ids]
  ;; As before, and how many were missing when it began: slow, not lost, when that falls to 0.
  (let [deadline (+ (System/currentTimeMillis) 60000)
        wanted (set ids)
        missing-now #(count (remove (set (map :orders/id (jdbc/execute! db ["SELECT id FROM orders WHERE id = ANY(?)" (into-array String wanted)]))) wanted))
        at-start (missing-now)]
    (loop []
      (let [missing (missing-now)]
        (if (or (zero? missing) (> (System/currentTimeMillis) deadline))
          (do (w/always (zero? missing) "every acknowledged order is in Postgres"
                        {:acknowledged (count wanted) :missing missing :missing_at_start at-start})
              (str missing " missing of " (count wanted) " (" at-start " at the start)"))
          (do (Thread/sleep 500) (recur)))))))

(.interrupt consumer-thread)
(def consumer-thread (doto (Thread. ^Runnable consume!) .start))
(verify [(place! "third-book")])

(w/explore-here! {:branches 24 :time-budget "10m"})

;; What run 2 found (21 of 22 timelines passing): one consumer neither dead nor reopening, 885
;; orders behind. A REPL in that timeline replayed to verify's start showed it: the thread
;; RUNNABLE in a socket read, next.jdbc's with-transaction asking the kept connection its
;; isolation level, the reply never coming (a fault cut the connection silently; pgjdbc waits
;; forever by default). The fix: the connection's reads and connects bounded, then the consumer
;; restarted (the old one ends after its poll).
(def db {:dbtype "postgresql" :host "postgres" :dbname "postgres" :user "postgres"
         :socketTimeout 30 :connectTimeout 10})

(reset! running false)
(.join consumer-thread 30000)
(reset! running true)
(def consumer-thread (doto (Thread. ^Runnable consume!) .start))
(verify [(place! "fourth-book")])

(w/explore-here! {:branches 24 :time-budget "10m"})
