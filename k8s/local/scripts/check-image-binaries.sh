#!/usr/bin/env bash
# Step 2.5, from PM-0006: containerd verifies the digest of the compressed blob
# it downloads, never the file it extracted, and the kubelet executes the
# extracted file. A silently corrupted etcd binary crashed with SIGSEGV while
# the running process carried on from page cache.
#
# This hashes the binary as the container sees it, through /proc/<pid>/root,
# so it reads what would be executed on the next start rather than what is
# currently in memory, and compares it with a baseline.
#
#   check-image-binaries.sh --update   write the baseline (after an upgrade)
#   check-image-binaries.sh            compare and write metrics
#
# Limit worth knowing: this catches corruption and accidental drift. It is not
# tamper protection, because anything that can rewrite the binary can rewrite
# the baseline next to it.
set -euo pipefail

BASELINE=${BASELINE:-/var/lib/node-exporter/binary-baseline.txt}
TEXTFILE_DIR=${TEXTFILE_DIR:-/var/lib/node-exporter/textfile}
TEXTFILE=${TEXTFILE_DIR}/binary_integrity.prom

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

# container name -> path of the binary inside that container
BINARIES="
etcd=/usr/local/bin/etcd
kube-apiserver=/usr/local/bin/kube-apiserver
kube-controller-manager=/usr/local/bin/kube-controller-manager
kube-scheduler=/usr/local/bin/kube-scheduler
kube-proxy=/usr/local/bin/kube-proxy
calico-node=/usr/bin/calico-node
"

# A check that finds nothing must fail, not report an empty success. On a node
# without crictl the loop below would simply find no containers and write a
# file full of nothing, which reads as "all good" on a dashboard.
if ! command -v crictl >/dev/null 2>&1; then
  echo "crictl not found: cannot inspect containers on this node" >&2
  exit 1
fi

mkdir -p "$TEXTFILE_DIR" "$(dirname "$BASELINE")"
[ -f "$BASELINE" ] || : > "$BASELINE"

tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.baseline"' EXIT

checked=0
failed=0

for entry in $BINARIES; do
  name=${entry%%=*}
  path=${entry#*=}

  # A node runs only some of these. A missing container is not a failure.
  id=$(crictl ps --name "^${name}$" -q 2>/dev/null | head -1) || true
  [ -n "$id" ] || continue

  pid=$(crictl inspect "$id" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["pid"])') || true
  [ -n "${pid:-}" ] || continue

  file="/proc/${pid}/root${path}"
  [ -r "$file" ] || continue

  hash=$(sha256sum "$file" | cut -d' ' -f1)
  checked=$((checked + 1))

  if [ "$UPDATE" = "1" ]; then
    echo "${name} ${hash}" >> "$tmp.baseline"
    echo "baseline ${name} ${hash}"
    continue
  fi

  known=$(awk -v n="$name" '$1 == n {print $2}' "$BASELINE" | head -1)
  if [ -z "$known" ]; then
    # No baseline yet for this binary: report unknown rather than pretending.
    echo "lab_binary_integrity{binary=\"${name}\"} -1" >> "$tmp"
    echo "no baseline for ${name} (${hash})" >&2
  elif [ "$known" = "$hash" ]; then
    echo "lab_binary_integrity{binary=\"${name}\"} 1" >> "$tmp"
  else
    echo "lab_binary_integrity{binary=\"${name}\"} 0" >> "$tmp"
    echo "MISMATCH ${name}: baseline ${known}, on disk ${hash}" >&2
    failed=$((failed + 1))
  fi
done

if [ "$checked" = "0" ]; then
  echo "no known binaries found on this node: nothing was verified" >&2
  exit 1
fi

if [ "$UPDATE" = "1" ]; then
  mv "$tmp.baseline" "$BASELINE"
  chmod 0644 "$BASELINE"
  echo "baseline written to ${BASELINE} (${checked} binaries)"
  exit 0
fi

{
  echo "# HELP lab_binary_integrity 1 matches the baseline, 0 differs, -1 no baseline."
  echo "# TYPE lab_binary_integrity gauge"
  cat "$tmp"
  echo "# HELP lab_binary_check_timestamp_seconds When the integrity check last ran."
  echo "# TYPE lab_binary_check_timestamp_seconds gauge"
  echo "lab_binary_check_timestamp_seconds $(date +%s)"
  echo "# HELP lab_binary_checked_total Binaries found and hashed on this node."
  echo "# TYPE lab_binary_checked_total gauge"
  echo "lab_binary_checked_total ${checked}"
} > "${TEXTFILE}.tmp"

mv "${TEXTFILE}.tmp" "$TEXTFILE"
chmod 0644 "$TEXTFILE"

echo "checked ${checked} binaries, ${failed} mismatched"
[ "$failed" = "0" ]
