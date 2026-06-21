# Kafka TLS/auth — Kube Secrets migration plan

Status: planned, not yet applied. Author: max toegang. Drafted by claude ·
claude-opus-4-8; reviewed by max.

## Why this exists

The broker today runs both listeners as PLAINTEXT (`kube/kafka.yaml`,
`KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT`).
That was a deliberate carry-over of the compose mesh's trust model across the
cut-over to k3s — the manifest itself notes "TLS/auth is a later, separate
change." This is that change, scoped as a plan only. It moves the broker's
listeners to TLS with SASL authentication and routes every credential through a
Kube Secret + scoped RBAC, following the fleet's `cloudflared-tunnel` reference
shape (`/Users/jane/work/cloudflared/kube`).

No secret value appears in this document, in any manifest in this repo, or in
any command an agent can see. Values are injected by max from his own terminal
via stdin at apply time. The manifests describe the *reference shape* only.

## Scope of the secret material

Two distinct kinds of secret material are involved. Keep them in separate
Secrets so their RBAC and rotation cadence stay independent:

1. **Broker TLS keystore material** — the broker's server certificate + private
   key (and the CA/truststore it trusts for mutual cases). The private key is
   the secret; the cert and CA are not strictly secret but travel with it.
2. **SASL credentials** — the broker's JAAS config (or, for SCRAM, the
   credentials provisioned into the broker), plus the per-client passwords that
   in-cluster consumers (schema-registry, delightd, paling) present.

The recommended posture for an in-cluster, single-broker laptop fleet:

- **INTERNAL listener** (in-cluster, `kafka.fleet.svc.cluster.local:9092`):
  `SASL_SSL` with `SCRAM-SHA-512`. TLS gives confidentiality + server identity;
  SCRAM gives per-client auth without shipping a keystore to every client. This
  is the listener schema-registry and every fleet producer/consumer use.
- **EXTERNAL listener** (`kafka.localhost:9094`, the host-client migration
  bridge): keep it on the same `SASL_SSL` profile or retire it once no host
  client remains. Do not leave one listener PLAINTEXT while the other is
  secured — a single open listener defeats the change.

`SCRAM-SHA-512` over `SSL` is preferred to mTLS-only auth here because adding a
new fleet client is "provision one SCRAM user" rather than "issue, distribute,
and rotate a client cert," which matches the cadence at which fleet services are
added.

## Secrets — reference shape (NO VALUES)

Following `cloudflared-tunnel`: a dedicated Secret per concern, created
out-of-band by max via stdin, **never** committed with a `data:`/`stringData:`
block, and **never** listed in `kustomization.yaml` (applying a valueless Secret
would mask the real one).

### `kafka-tls` — broker keystore/truststore material

```
# REFERENCE SHAPE ONLY — do not apply, do not add to kustomization.yaml.
# apiVersion: v1
# kind: Secret
# metadata:
#   name: kafka-tls
#   namespace: fleet
#   labels:
#     app.kubernetes.io/name: kafka
#     app.kubernetes.io/part-of: fleet
# type: Opaque
# # keys (created out-of-band, see below):
# #   keystore.p12     — broker server cert + private key (PKCS#12)
# #   truststore.p12   — CA the broker trusts
# #   keystore.creds   — keystore password (single line)
# #   truststore.creds — truststore password (single line)
```

### `kafka-sasl` — broker + client SCRAM credentials

```
# REFERENCE SHAPE ONLY — do not apply, do not add to kustomization.yaml.
# apiVersion: v1
# kind: Secret
# metadata:
#   name: kafka-sasl
#   namespace: fleet
#   labels:
#     app.kubernetes.io/name: kafka
#     app.kubernetes.io/part-of: fleet
# type: Opaque
# # keys (created out-of-band, see below):
# #   broker_jaas.conf  — broker inter-broker + listener JAAS config
# #   admin.password    — SCRAM password for the broker/admin principal
```

A separate Secret per consuming service holds *that client's* SCRAM password
(e.g. `schema-registry-kafka-sasl` with key `password`), so each client's RBAC
reads only its own credential. This document specifies the broker side; each
client repo adds its own one-key Secret + reader Role on the same pattern.

## Injecting the values (max runs these from his own terminal)

Values never enter a file, git, or an agent context. Create each Secret by
streaming the bytes into stdin so they stay off disk and out of shell history.

Keystore/truststore (binary PKCS#12 + password files generated on max's box):

```
kubectl create secret generic kafka-tls -n fleet \
  --from-file=keystore.p12=./kafka.keystore.p12 \
  --from-file=truststore.p12=./kafka.truststore.p12 \
  --from-file=keystore.creds=/dev/stdin
# paste the keystore password, Ctrl-D; repeat per --from-file=/dev/stdin key,
# or generate the .creds files locally and --from-file them, then shred them.
```

Single-line credentials (SCRAM passwords, JAAS) via stdin so nothing lands on
disk:

```
kubectl create secret generic kafka-sasl -n fleet \
  --from-file=admin.password=/dev/stdin
# paste the admin SCRAM password, then Ctrl-D on its own line.
```

(The `broker_jaas.conf` key, being multi-line, is generated to a local temp
file, `--from-file`'d, and shredded — it still never reaches git or an agent.)

Rotate by recreating the Secret (`kubectl create ... --dry-run=client -o yaml |
kubectl apply -f -` via the same stdin paste) and restarting the broker:

```
kubectl rollout restart statefulset/kafka -n fleet
```

The Secret must exist before the broker starts — fail-closed by design, matching
cloudflared.

## RBAC — named-resource Role + RoleBinding (reference pattern)

Exactly the `cloudflared-secret-reader` shape: a dedicated ServiceAccount, a
Role granting `get` on the *named* Secrets only, and a RoleBinding. The broker
reads its TLS + SASL material and nothing else in the namespace. This becomes a
new `kube/rbac.yaml` in this repo (and the StatefulSet gets
`serviceAccountName: kafka`).

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafka
  namespace: fleet
  labels:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/part-of: fleet
# the broker reads its own Secrets via projected volumes/secretKeyRef; the
# kubelet projects those, so the SA needs no API token for them. Do not
# auto-mount a token the workload does not otherwise use.
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kafka-secret-reader
  namespace: fleet
  labels:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/part-of: fleet
rules:
  # scoped to exactly the two named Secrets — not all secrets in the namespace.
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["kafka-tls", "kafka-sasl"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kafka-secret-reader
  namespace: fleet
  labels:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/part-of: fleet
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kafka-secret-reader
subjects:
  - kind: ServiceAccount
    name: kafka
    namespace: fleet
```

Note the same caveat as the cloudflared rbac: a pod consuming a Secret via a
projected volume or `secretKeyRef` does not itself call the API to read it — the
kubelet projects it. This Role scopes any API access the workload's identity
*would* have to the two named Secrets, keeping least-privilege named.

## How the broker consumes it

The confluent `cp-kafka` image takes TLS + SASL through `KAFKA_*` env and
mounted keystore files. The keystore material is a **projected volume** (binary
files belong on disk, not in env); the SCRAM/JAAS passwords come through
`secretKeyRef` env (or the JAAS file via the same volume). Sketch of the
StatefulSet delta against today's `kube/kafka.yaml`:

```yaml
spec:
  template:
    spec:
      serviceAccountName: kafka            # new — from rbac.yaml above
      containers:
        - name: kafka
          env:
            # was: INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: INTERNAL:SASL_SSL,EXTERNAL:SASL_SSL
            - name: KAFKA_SASL_ENABLED_MECHANISMS
              value: SCRAM-SHA-512
            - name: KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL
              value: SCRAM-SHA-512
            - name: KAFKA_SSL_KEYSTORE_FILENAME
              value: keystore.p12
            - name: KAFKA_SSL_KEYSTORE_TYPE
              value: PKCS12
            - name: KAFKA_SSL_TRUSTSTORE_FILENAME
              value: truststore.p12
            - name: KAFKA_SSL_TRUSTSTORE_TYPE
              value: PKCS12
            # passwords come from the Secret at runtime — never inlined here.
            - name: KAFKA_SSL_KEYSTORE_CREDENTIALS
              value: keystore.creds      # confluent reads this file from the
            - name: KAFKA_SSL_TRUSTSTORE_CREDENTIALS  #   secrets mount dir
              value: truststore.creds
            - name: KAFKA_SSL_KEY_CREDENTIALS
              value: keystore.creds
            # JAAS for the listeners, sourced from the mounted file.
            - name: KAFKA_OPTS
              value: "-Djava.security.auth.login.config=/etc/kafka/secrets/broker_jaas.conf"
          volumeMounts:
            - name: kafka-tls
              mountPath: /etc/kafka/secrets   # confluent's default secrets dir
              readOnly: true
            - name: kafka-sasl
              mountPath: /etc/kafka/sasl
              readOnly: true
      volumes:
        - name: kafka-tls
          secret:
            secretName: kafka-tls
        - name: kafka-sasl
          secret:
            secretName: kafka-sasl
```

(`KAFKA_ADVERTISED_LISTENERS` keeps the same hostnames; only the protocol map
and the security config change. The advertised FQDN must match the broker
cert's SAN — `kafka.fleet.svc.cluster.local` — or TLS handshakes fail.)

## Client-side changes this forces (tracked, not done here)

Securing the broker is not complete until every client speaks `SASL_SSL`:

- **schema-registry** (`kube/schema-registry.yaml`): today bootstraps with
  `PLAINTEXT://kafka.fleet.svc.cluster.local:9092`. Must change to
  `SASL_SSL://...:9092` plus `SCHEMA_REGISTRY_KAFKASTORE_SASL_*` and SSL
  truststore env, with its SCRAM password from its own one-key Secret +
  reader Role. This is a same-PR change since SR lives in this repo.
- **delightd / paling / other producers**: each consumes the broker via the
  franz-go producer convention. Each needs the CA truststore + its own SCRAM
  password from a per-service Secret on this same pattern, landed in its own
  repo. Track as a follow-up per producer; the broker change must land first or
  all clients fail closed (which is the intended, safe failure direction).

## Migration steps (ordered)

1. **Generate material on max's box** (off-fleet): broker keystore (cert with
   SAN `kafka.fleet.svc.cluster.local`, and `kafka.localhost` if EXTERNAL is
   kept), truststore from the CA, and SCRAM passwords for `admin` and each
   client principal. None of this touches the repo.
2. **Inject Secrets** via the stdin commands above: `kafka-tls`, `kafka-sasl`,
   and each client's per-service SASL Secret.
3. **Add `kube/rbac.yaml`** (ServiceAccount + named Role + RoleBinding above);
   list it first in `kube/kustomization.yaml`.
4. **Edit `kube/kafka.yaml`**: `serviceAccountName: kafka`, the protocol-map +
   SSL/SASL env, and the two Secret volume mounts.
5. **Edit `kube/schema-registry.yaml`** to bootstrap over `SASL_SSL` with its
   SCRAM creds + truststore.
6. **Validate offline**: `kubectl kustomize kube/ | kubeconform -strict
   -ignore-missing-schemas` (the fleet's offline validator; a live cluster is
   not assumed).
7. **Provision SCRAM users in the broker** (one-time, for SCRAM-SHA-512): run
   `kafka-configs --bootstrap-server ... --alter --add-config 'SCRAM-SHA-512=...'`
   for each principal. With Zookeeper present (this deployment), users can be
   pre-created against ZK before the broker enforces SASL; sequence this so the
   inter-broker principal exists before the listener flips, or the broker cannot
   talk to itself.
8. **Primary agent applies** (`kubectl apply -k kube/`) and
   `kubectl rollout restart statefulset/kafka -n fleet`. Subagents do not apply.
9. **Verify**: broker readiness probe (`kafka-broker-api-versions`) must move to
   `SASL_SSL` with creds too, or readiness will fail against the now-secured
   listener — update the probe command in the same edit. Then confirm SR and one
   producer reconnect.

## Sequencing caveat (the one that bites)

The readiness/liveness probes in today's `kube/kafka.yaml` connect PLAINTEXT to
`localhost:9092`. Once the listener is `SASL_SSL`, those probes must present
credentials or the broker will be marked unready forever and the rollout will
hang. Update the probe `command` to pass a `--command-config` client properties
file (sourced from a mounted Secret key) in the *same* change that flips the
protocol map. This is the single most likely cause of a stuck migration and is
called out so it is not discovered at apply time.
