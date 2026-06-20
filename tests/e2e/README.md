# kafka-tier end-to-end test

`kafka-tier-e2e.sh` stands the kafka tier's kube manifests up on a real cluster
and asserts the runtime behaviours that `kubectl apply --dry-run` cannot. Every
check here corresponds to a defect found during the compose→kubernetes cutover,
so the suite is the regression gate for that class of failure.

## Why it exists

`--dry-run=server` validates schema and admission, not runtime. The cutover
surfaced four defects that only appear once the pods run:

| Failure | Caught by |
|---|---|
| zookeeper never Ready (4lw `ruok` not whitelisted) | `ready.zookeeper`, `invariants.zkWhitelist` |
| kafka deadlocks on its own advertised FQDN (headless svc only publishes Ready endpoints) | `ready.kafka`, `invariants.publishNotReadyAddresses` |
| `InconsistentClusterIdException` after a zk restart (txn log not persisted) | `cluster_id_persists`, `invariants.zkTxnlogPersisted` |
| schema-registry exits 1 (`SCHEMA_REGISTRY_PORT` link-env collision) | `ready.schema-registry`, `invariants.enableServiceLinks` |

The `cluster_id_persists` check is the subtle one: it captures `/cluster/id`,
deletes the zookeeper pod, waits for it back, and asserts the id is unchanged
*and* kafka is still Ready. It only passes if zookeeper persists its transaction
log across the restart.

## Running

```sh
task e2e                      # JSON result to stdout
task e2e -- --human           # readable table
task e2e -- --keep            # leave the namespace up for inspection
./tests/e2e/kafka-tier-e2e.sh --human --timeout 240
```

Flags: `--human`, `--keep`, `--timeout SECONDS`, `--kubeconfig PATH`,
`--context NAME`.

## Hermeticity

The test applies `tests/e2e/overlay` — the base `kube/` manifests retargeted to
a throwaway `kafka-e2e` namespace with **dynamic** storage (the cluster's
default storageclass) instead of the host-path volumes. It never touches `~/var`
or the live `fleet` namespace, and it tears the namespace down on exit (`--keep`
to retain). It needs a cluster with a default provisioner — k3d and kind both
ship `local-path`.

## Exit code

`0` only if every check passes; non-zero otherwise. JSON output carries
`"ok": true|false` and a per-check breakdown for machine consumers.
