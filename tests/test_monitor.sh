#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
APP_PID=""

cleanup() {
  if [[ -n "${APP_PID}" ]]; then
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_DIR}/upload" "${TEST_DIR}/logs"
printf '%s
' 'agent_api_key_test' > "${TEST_DIR}/t_secret.key"

export AGENT_HOME="${TEST_DIR}"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="${TEST_DIR}/upload"
export AGENT_KEY_PATH="${TEST_DIR}/t_secret.key"
export AGENT_LOG_DIR="${TEST_DIR}/logs"
export AGENT_SERVICE_USER="$(id -un)"

python3 "${REPO_ROOT}/agent_app.py" > "${TEST_DIR}/boot.log" 2>&1 &
APP_PID=$!

for _ in {1..20}; do
  if ss -ltnH | awk '$4 ~ /:15034$/ { found=1 } END { exit !found }'; then
    break
  fi
  sleep 0.25
done

grep -q 'Agent READY' "${TEST_DIR}/boot.log"
AGENT_LOG_FILE="${TEST_DIR}/logs/monitor.log" AGENT_MONITOR_LOCK="${TEST_DIR}/monitor.lock" PROCESS_PATTERN='agent_app.py'   bash "${REPO_ROOT}/monitor.sh"

grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9]+\.[0-9]% MEM:[0-9]+\.[0-9]% DISK_USED:[0-9]+%$'   "${TEST_DIR}/logs/monitor.log"

kill "${APP_PID}"
wait "${APP_PID}" 2>/dev/null || true
APP_PID=""

if AGENT_LOG_FILE="${TEST_DIR}/logs/monitor.log"   AGENT_MONITOR_LOCK="${TEST_DIR}/monitor.lock"   PROCESS_PATTERN='agent_app.py'   bash "${REPO_ROOT}/monitor.sh"; then
  echo "monitor.sh should fail when the process is absent" >&2
  exit 1
fi

echo "All tests passed."
