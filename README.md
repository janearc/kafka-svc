# kafka-svc

The fleet's message backbone and the canonical home for its event contracts.
Services do not define their own wire formats; they consume the Protobuf
contracts defined here. This repository owns three things: the broker topology,
the schema contracts, and the governance that keeps those contracts from
breaking.

## Topology

`docker compose up -d` brings up three services:

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| `kafka` | `confluentinc/cp-kafka:7.5.0` | 9092 | Broker. Advertises `PLAINTEXT://kafka.localhost:9092`. |
| `zookeeper` | `confluentinc/cp-zookeeper:7.5.0` | 2181 | Broker coordination. |
| `schema-registry` | `confluentinc/cp-schema-registry:7.5.0` | 8081 | Contract enforcement. Routed as `schema-registry.localhost`. |

The registry's default compatibility is pinned to `FULL_TRANSITIVE`
(`SCHEMA_REGISTRY_SCHEMA_COMPATIBILITY_LEVEL`): a new schema version must be
both forward- and backward-compatible with *every* prior version, not just the
last. The practical consequence is the central rule of this repo: **fields are
never removed, only deprecated** (retained a minimum of three release cycles).

> Operational note: the broker advertises `kafka.localhost:9092`. Clients
> resolve that name via the fleet's host/Traefik routing; in-compose,
> `schema-registry` bootstraps against `kafka:9092` directly.

## Contracts

Source of truth lives under `proto/`, packaged by domain and version:

| Package | Messages | Emitted by |
|---------|----------|------------|
| `observability.v1` | `ServiceHealthHeartbeat`, `TokenBurnEvent`, `WidgetStatePayload`, `FleetMetrics`, `QuotaMetrics` | every fleet service (health); agents (token burn); `obs-svc-agg` (widget) |
| `delight.v1` | `BackupEvent`, `ServiceBackupStatus` | `delightd` |

Generated language bindings are **not committed**. Run `task generate` to emit
them into `gen/` (gitignored); consumers regenerate from this contract.

### Browsable docs

For a human-readable view of every message, field, and comment, generate the
static HTML docs:

```bash
task docs   # -> docs/protos/index.html
```

Then open the page directly in a browser — no server, no container images:

```bash
open docs/protos/index.html      # macOS
# or just point a browser at the file:// path
```

The output is a single self-contained page and is **not committed**
(gitignored); regenerate it from the contracts whenever they change.
Generation uses `buf`'s remote doc plugin
(`buf.build/community/pseudomuto-doc`), so nothing is installed locally; if the
registry is unreachable, `scripts/gen-proto-docs.sh` falls back to a local
`protoc-gen-doc` it `go install`s on demand.

## Naming conventions

**Topics** are lowercase and treated as a stable API. Hierarchy levels are
separated by dots; a level that needs more than one word is kebab-cased within
that level (a hypothetical `token-burn` would be one level, not two). This is
the Confluent convention — `.` is structure, `-` is intra-level word
separation.

The provisioned topic set is declared once in big-little-mesh
(`admin/topics.go`, `FleetTopics`) — code is truth on the names; this table
mirrors it and says what each topic carries today:

| Topic | Carries |
|-------|---------|
| `observability.events` | `observability.v1.ServiceHealthHeartbeat`, `observability.v1.TokenBurnEvent` — one topic; `RecordNameStrategy` keeps per-message subjects, so no per-message topic exists |
| `bento.events` | `bento.v1.BentoLifecycleEvent` |
| `delight.events` | `delight.v1.BackupEvent` |
| `paling.events` | `paling.v1.BanchanLifecycleEvent` |
| `magpie.events` | declared ahead of magpie's events landing |

`observability.v1.TransferEvent` (emitted by taco) has a subject but no
settled topic: taco defaults to `observability.transfers`, which `FleetTopics`
does not provision — an open inconsistency tracked on the taco repo, not a row
in this table until it is resolved.

**Subjects** use `RecordNameStrategy`: the registry subject is the message's
fully-qualified name (e.g. `observability.v1.ServiceHealthHeartbeat`), not the
topic. Compatibility is therefore enforced per message type, independent of
which topic carries it, which is what makes the deprecate-never-delete rule
enforceable across the whole fleet.

## Governance

`buf` gates every change. The targets are defined in `Taskfile.yml` and run with
[Task](https://taskfile.dev) (`go-task`); both `task` and `buf` must be on
`PATH` (they run in CI / pre-commit, not from the daemon). `task generate` is a
thin wrapper over `buf generate` — it produces the language bindings, it does
not change any contract.

```bash
task lint      # buf lint: STANDARD lint rules
task breaking  # buf breaking: reject FULL_TRANSITIVE violations against main
task generate  # buf generate: emit bindings into gen/ (not committed)
task ci        # lint + breaking
```
