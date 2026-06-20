#!/usr/bin/env bash
#
# End-to-end test for the kafka tier's kubernetes manifests.
#
# Stands the tier up in a throwaway, dynamically-provisioned namespace
# (tests/e2e/overlay) and asserts the runtime behaviours that --dry-run cannot:
# every pod reaches Ready, the kafka cluster id survives a zookeeper restart,
# a produce/consume roundtrip works, and schema-registry answers over HTTP.
# Each check maps to a defect found during the compose->k8s cutover, so this
# is the regression gate for that class of failure.
#
# JSON to stdout by default (machine-first); --human for a table. Logs to
# stderr. Exit 0 only if every check passes.
#
# Usage:
#   tests/e2e/kafka-tier-e2e.sh [--human] [--keep] [--timeout SECONDS]
#                               [--kubeconfig PATH] [--context NAME]
#
# Requires: kubectl, a reachable cluster with a default storageclass
# (k3d/kind both ship local-path). Does NOT touch ~/var or the live `fleet`
# namespace.

set -uo pipefail

NS="kafka-e2e"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="${SCRIPT_DIR}/overlay"
HUMAN=0
KEEP=0
TIMEOUT=300
KUBECTL=(kubectl)

while [ $# -gt 0 ]; do
  case "$1" in
    --human)      HUMAN=1 ;;
    --keep)       KEEP=1 ;;
    --timeout)    TIMEOUT="$2"; shift ;;
    --kubeconfig) KUBECTL+=(--kubeconfig "$2"); shift ;;
    --context)    KUBECTL+=(--context "$2"); shift ;;
    -h|--help)    grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[e2e] unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { echo "[e2e] $*" >&2; }

# check results accumulate here as JSON object fragments
declare -a RESULTS=()
FAILED=0
record() {
  # record <check> <pass|fail> <detail>
  local status="$2"
  [ "$status" = "fail" ] && FAILED=$((FAILED + 1))
  # escape backslashes and double-quotes in the detail for JSON safety
  local detail="${3//\\/\\\\}"; detail="${detail//\"/\\\"}"
  RESULTS+=("{\"check\":\"$1\",\"status\":\"$status\",\"detail\":\"$detail\"}")
  log "[$status] $1 -- $3"
}

k() { "${KUBECTL[@]}" "$@"; }

teardown() {
  if [ "$KEEP" = "1" ]; then
    log "--keep set; leaving namespace $NS in place"
    return
  fi
  log "tearing down namespace $NS"
  k delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
trap teardown EXIT

emit() {
  local ok="true"; [ "$FAILED" -gt 0 ] && ok="false"
  if [ "$HUMAN" = "1" ]; then
    printf '\n%-28s %s\n' "CHECK" "STATUS"
    printf '%s\n' "-------------------------------------------"
    local r check status
    for r in "${RESULTS[@]}"; do
      check=$(printf '%s' "$r" | sed -E 's/.*"check":"([^"]*)".*/\1/')
      status=$(printf '%s' "$r" | sed -E 's/.*"status":"([^"]*)".*/\1/')
      printf '%-28s %s\n' "$check" "$status"
    done
    printf '%s\n' "-------------------------------------------"
    printf 'result: %s (%d checks, %d failed)\n' "$ok" "${#RESULTS[@]}" "$FAILED"
  else
    local joined; joined=$(IFS=,; echo "${RESULTS[*]}")
    printf '{"suite":"kafka-tier-e2e","namespace":"%s","ok":%s,"checks_total":%d,"checks_failed":%d,"checks":[%s]}\n' \
      "$NS" "$ok" "${#RESULTS[@]}" "$FAILED" "$joined"
  fi
}

# ---------------------------------------------------------------------------
# 0. static invariants -- render the overlay and assert the four structural
#    fixes are present. Cheap, needs no cluster; fails fast if a manifest
#    regression dropped one of them.
# ---------------------------------------------------------------------------
log "rendering overlay for static invariant checks"
RENDER="$(k kustomize "$OVERLAY" 2>/dev/null)"
if [ -z "$RENDER" ]; then
  record invariants.render fail "kubectl kustomize produced no output"
else
  record invariants.render pass "overlay renders"
  c=$(printf '%s' "$RENDER" | grep -c 'enableServiceLinks: false')
  [ "$c" -eq 3 ] && record invariants.enableServiceLinks pass "present on all 3 pods" \
                 || record invariants.enableServiceLinks fail "expected 3, found $c"
  printf '%s' "$RENDER" | grep -q 'publishNotReadyAddresses: true' \
    && record invariants.publishNotReadyAddresses pass "set on kafka service" \
    || record invariants.publishNotReadyAddresses fail "missing on kafka service"
  printf '%s' "$RENDER" | grep -q '4lw.commands.whitelist' \
    && record invariants.zkWhitelist pass "zk 4lw whitelist set" \
    || record invariants.zkWhitelist fail "zk 4lw whitelist missing"
  printf '%s' "$RENDER" | grep -q '/var/lib/zookeeper/log' \
    && record invariants.zkTxnlogPersisted pass "zk txnlog dir mounted" \
    || record invariants.zkTxnlogPersisted fail "zk txnlog dir not mounted"
fi

# ---------------------------------------------------------------------------
# 1. apply + readiness -- every pod in the tier reaches Ready.
# ---------------------------------------------------------------------------
# Clear any lingering namespace first so back-to-back runs (or a prior --keep /
# interrupted run) don't collide with a still-Terminating namespace, which would
# make `apply` fail. --wait blocks until it is fully gone.
if k get namespace "$NS" >/dev/null 2>&1; then
  log "found a prior $NS namespace; deleting and waiting for it to clear"
  k delete namespace "$NS" --wait=true --timeout="${TIMEOUT}s" >&2 2>&1 || true
fi

log "applying overlay to namespace $NS"
if ! k apply -k "$OVERLAY" >&2; then
  record apply fail "kubectl apply -k failed"
  emit; exit 1
fi
record apply pass "overlay applied"

# Wait on each workload's rollout in dependency order (zk -> kafka -> sr) rather
# than a one-shot per-pod `kubectl wait`: rollout status tolerates the slow cold
# start (dynamic PV provisioning + JVM warmup) and reflects the workload's own
# readiness gate, so a slow-but-healthy kafka is not reported as failed while a
# dependent that comes up later is reported as ready.
ready_ok=1
for entry in "zookeeper:statefulset/zookeeper" \
             "kafka:statefulset/kafka" \
             "schema-registry:deployment/schema-registry"; do
  app="${entry%%:*}"; obj="${entry#*:}"
  log "waiting for $obj rollout (timeout ${TIMEOUT}s)"
  if k rollout status "$obj" -n "$NS" --timeout="${TIMEOUT}s" >&2 2>&1; then
    record "ready.$app" pass "rollout complete"
  else
    record "ready.$app" fail "rollout did not complete within ${TIMEOUT}s"
    ready_ok=0
  fi
done

# the behavioural checks below need a serving broker; skip them if the tier
# never came up, but still emit a complete report.
if [ "$ready_ok" -ne 1 ]; then
  record cluster_id_persists skip "tier not Ready"
  record produce_consume    skip "tier not Ready"
  record schema_registry_http skip "tier not Ready"
  emit; exit 1
fi

get_cluster_id() {
  k exec -n "$NS" zookeeper-0 -- zookeeper-shell localhost:2181 get /cluster/id 2>/dev/null \
    | grep -oE '"id":"[^"]+"' | sed -E 's/"id":"([^"]+)"/\1/' | head -1
}

# ---------------------------------------------------------------------------
# 2. REGRESSION: the kafka /cluster/id must survive a zookeeper restart.
#    This is the subtle one -- it only passes if zk persists its transaction
#    log (not just snapshots), otherwise the restarted zk loses /cluster/id,
#    the broker mints a fresh one, and it stops matching kafka's meta.properties
#    (InconsistentClusterIdException).
# ---------------------------------------------------------------------------
log "regression: capturing /cluster/id, restarting zookeeper, re-checking"
ID_BEFORE="$(get_cluster_id)"
if [ -z "$ID_BEFORE" ]; then
  record cluster_id_persists fail "could not read /cluster/id before restart"
else
  k delete pod zookeeper-0 -n "$NS" >&2 2>&1
  k rollout status statefulset/zookeeper -n "$NS" --timeout="${TIMEOUT}s" >&2 2>&1
  k wait --for=condition=ready pod -l app.kubernetes.io/name=zookeeper \
     -n "$NS" --timeout="${TIMEOUT}s" >&2 2>&1
  ID_AFTER="$(get_cluster_id)"
  KAFKA_READY="$(k get pod kafka-0 -n "$NS" \
     -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)"
  if [ "$ID_BEFORE" = "$ID_AFTER" ] && [ "$KAFKA_READY" = "True" ]; then
    record cluster_id_persists pass "id $ID_BEFORE stable across zk restart; kafka still Ready"
  else
    record cluster_id_persists fail \
      "before=$ID_BEFORE after=${ID_AFTER:-<none>} kafkaReady=${KAFKA_READY:-<none>}"
  fi
fi

# ---------------------------------------------------------------------------
# 3. produce/consume roundtrip on a throwaway topic.
# ---------------------------------------------------------------------------
log "produce/consume roundtrip"
MSG="e2e-$(date +%s)-$RANDOM"
RT="$(k exec -n "$NS" kafka-0 -- bash -c "
  kafka-topics --bootstrap-server localhost:9092 --create --topic e2e.roundtrip \
    --partitions 1 --replication-factor 1 >/dev/null 2>&1
  echo '$MSG' | kafka-console-producer --bootstrap-server localhost:9092 \
    --topic e2e.roundtrip >/dev/null 2>&1
  kafka-console-consumer --bootstrap-server localhost:9092 --topic e2e.roundtrip \
    --from-beginning --max-messages 1 --timeout-ms 12000 2>/dev/null
  kafka-topics --bootstrap-server localhost:9092 --delete --topic e2e.roundtrip >/dev/null 2>&1
" 2>/dev/null)"
if printf '%s' "$RT" | grep -q "$MSG"; then
  record produce_consume pass "message roundtripped"
else
  record produce_consume fail "did not read back the produced message"
fi

# ---------------------------------------------------------------------------
# 4. schema-registry answers over HTTP (proves it connected to kafka and
#    initialized the _schemas topic).
# ---------------------------------------------------------------------------
log "schema-registry HTTP check"
CODE="$(k exec -n "$NS" kafka-0 -- curl -s -o /dev/null -w '%{http_code}' \
  -m 10 http://schema-registry:8081/subjects 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  record schema_registry_http pass "/subjects returned 200"
else
  record schema_registry_http fail "/subjects returned ${CODE:-<no response>}"
fi

emit
[ "$FAILED" -eq 0 ]
