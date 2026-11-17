# CI demo

The smallest repository `determinismo-ci` runs (docs/PRODUCTS.md): a Python node with pytest and
three tests, one that passes, one flaky (it fails when a random byte is low), one that always
fails. `ci.json` names the system (`compose.yaml`), the node, the setup, how the tests are
listed and run, the shards and each shard's timelines, and the files the setup depends on.

```
cd examples/ci-demo && determinismo-ci --config ci.json --serve http://127.0.0.1:7878
```

Expected: shard 1 pass, shard 2 flaky (failing in some of its 12 timelines), shard 3 fail, each
with its run on serve; exit status 1. A second run with nothing changed starts from the setup's
cached snapshot.
