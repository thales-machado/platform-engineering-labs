#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 <lab-dir>   e.g. $0 k8s/local" >&2; exit 1; }
[[ $# -eq 1 ]] || usage

here="$(cd "$(dirname "$0")" && pwd)"
lab="$1"
[[ -f "$lab/diagram.mmd" ]] || { echo "missing $lab/diagram.mmd" >&2; exit 1; }
command -v mmdc >/dev/null || { echo "mmdc not found: npm i -g @mermaid-js/mermaid-cli" >&2; exit 1; }

[[ -d "$here/node_modules" ]] || npm --prefix "$here" ci --silent
node "$here/build-pack.js" >/dev/null

mmdc -i "$lab/diagram.mmd" -o "$lab/diagram.png" \
  -b "#0b1120" -w 1600 -s 2 \
  --iconPacksNamesAndUrls "lab#data:application/json;base64,$(base64 -w0 "$here/lab.json")"

echo "rendered $lab/diagram.png"
