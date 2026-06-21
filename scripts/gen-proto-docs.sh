#!/usr/bin/env bash
# Generate static, browsable HTML documentation for the protobuf contracts.
#
# Output:  docs/protos/index.html  — a single self-contained page you open
#          directly in a browser. No server and no container images.
#
# Primary path uses buf's REMOTE doc plugin (buf.build/community/pseudomuto-doc),
# so nothing is installed locally. If buf cannot reach the registry (the fleet
# network blocks DNS/github intermittently — that's the environment, not a bug),
# this falls back to a local protoc-gen-doc that it `go install`s on demand.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="docs/protos"
mkdir -p "$OUT_DIR"

echo "==> generating proto docs via buf remote plugin"
if buf generate --template buf.gen.docs.yaml; then
  echo "==> wrote ${OUT_DIR}/index.html (remote plugin)"
  exit 0
fi

echo "==> remote plugin unreachable; falling back to a local protoc-gen-doc"

# Install the doc generator into GOBIN if it isn't already present. This is a
# go-run-class fetch (source build), not a container image pull.
if ! command -v protoc-gen-doc >/dev/null 2>&1; then
  echo "==> go install protoc-gen-doc"
  go install github.com/pseudomuto/protoc-gen-doc/cmd/protoc-gen-doc@latest
fi

# Make the freshly installed binary visible to buf.
export PATH="$(go env GOBIN):$(go env GOPATH)/bin:${PATH}"

buf generate --template - <<'YAML'
version: v2
plugins:
  - local: protoc-gen-doc
    out: docs/protos
    opt:
      - html,index.html
YAML

echo "==> wrote ${OUT_DIR}/index.html (local plugin)"
