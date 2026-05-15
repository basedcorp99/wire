#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/wire.app"
MODE="${1:-}"

pkill -x wire 2>/dev/null || true
"$ROOT_DIR/run.sh"

if [[ "$MODE" == "--verify" ]]; then
  sleep 1
  pgrep -x wire >/dev/null
  echo "wire launched"
elif [[ "$MODE" == "--logs" ]]; then
  /usr/bin/log stream --style compact --predicate "process == 'wire'"
fi
