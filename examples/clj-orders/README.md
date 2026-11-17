# Orders in Clojure, on Kafka and Postgres, developed in a fast VM

The system: a Kafka broker (KRaft, one node), Postgres, and a Clojure JVM with an nREPL where
the service is written, with nothing of it in the image: orders taken over HTTP, put on Kafka, a
consumer writing them to Postgres. Developed at the REPL in a fast VM (docs/DEVELOPING.md), then
explored from there: the same machine, deterministic timelines with faults.

```
determinismo-sandbox create --compose examples/clj-orders/compose.yaml --vcpus 4 --memory-mib 6144
infra/host/nrepl-proxy.py --dev <the machine's directory> --node app --listen 127.0.0.1:7888
```

Results: REPORT.md (four explorations from the REPL: the bugs they found in the service, the fixes written there, and what determinismo needed on the way).
