#!/usr/bin/env bash
set -uo pipefail

export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PROCESS_PATTERN="${PROCESS_PATTERN:-agent_app.py}"
PORT="${AGENT_PORT:-15034}"
LOG_FILE="${AGENT_LOG_FILE:-/var/log/agent-app/monitor.log}"
LOCK_FILE="${AGENT_MONITOR_LOCK:-/tmp/agent-app-monitor.lock}"
MAX_LOG_BYTES=$((10 * 1024 * 1024))
MAX_ARCHIVES=10

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "[INFO] Another monitor instance is running; this run is skipped."
  exit 0
fi

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

health_failed=0
pid_list="$(pgrep -f -- "${PROCESS_PATTERN}" 2>/dev/null || true)"
if [[ -n "${pid_list}" ]]; then
  PID="$(printf '%s
' "${pid_list}" | head -n 1)"
  echo "Checking process '${PROCESS_PATTERN}'... [OK] (PID: ${PID})"
else
  PID="-"
  echo "Checking process '${PROCESS_PATTERN}'... [FAIL]"
  health_failed=1
fi

if command -v ss >/dev/null 2>&1 &&
  ss -ltnH | awk -v port="${PORT}" '$4 ~ (":" port "$") { found=1 } END { exit !found }'; then
  echo "Checking port ${PORT}... [OK]"
else
  echo "Checking port ${PORT}... [FAIL]"
  health_failed=1
fi

if (( health_failed != 0 )); then
  echo "[ERROR] Health check failed."
  exit 1
fi

firewall_active=0
firewall_name="none"
if command -v ufw >/dev/null 2>&1; then
  if grep -Eq '^[[:space:]]*ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null ||
    ufw status 2>/dev/null | grep -q '^Status: active'; then
    firewall_active=1
    firewall_name="ufw"
  fi
fi
if (( firewall_active == 0 )) && command -v firewall-cmd >/dev/null 2>&1; then
  if firewall-cmd --state 2>/dev/null | grep -q '^running$'; then
    firewall_active=1
    firewall_name="firewalld"
  fi
fi

if (( firewall_active == 1 )); then
  echo "Checking firewall... [OK] (${firewall_name})"
else
  echo "[WARNING] Firewall is inactive or its state cannot be confirmed."
fi

read_cpu_sample() {
  local _cpu user nice system idle iowait irq softirq steal _guest
  read -r _cpu user nice system idle iowait irq softirq steal _guest < /proc/stat
  CPU_IDLE=$((idle + iowait))
  CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

read_cpu_sample
idle_before="${CPU_IDLE}"
total_before="${CPU_TOTAL}"
sleep 1
read_cpu_sample
idle_delta=$((CPU_IDLE - idle_before))
total_delta=$((CPU_TOTAL - total_before))
CPU_USAGE="$(awk -v idle="${idle_delta}" -v total="${total_delta}"   'BEGIN { if (total <= 0) printf "0.0"; else printf "%.1f", (1 - idle / total) * 100 }')"

read -r mem_total mem_available < <(
  awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { available=$2 }
    END { print total, available }
  ' /proc/meminfo
)
MEM_USAGE="$(awk -v total="${mem_total}" -v available="${mem_available}"   'BEGIN { if (total <= 0) printf "0.0"; else printf "%.1f", (total - available) / total * 100 }')"
DISK_USED="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"

echo
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used : ${DISK_USED}%"
echo

if awk -v value="${CPU_USAGE}" 'BEGIN { exit !(value > 20) }'; then
  echo "[WARNING] CPU threshold exceeded (${CPU_USAGE}% > 20%)"
fi
if awk -v value="${MEM_USAGE}" 'BEGIN { exit !(value > 10) }'; then
  echo "[WARNING] MEM threshold exceeded (${MEM_USAGE}% > 10%)"
fi
if awk -v value="${DISK_USED}" 'BEGIN { exit !(value > 80) }'; then
  echo "[WARNING] DISK threshold exceeded (${DISK_USED}% > 80%)"
fi

log_dir="$(dirname -- "${LOG_FILE}")"
if [[ ! -d "${log_dir}" || ! -w "${log_dir}" ]]; then
  echo "[ERROR] Log directory is not writable: ${log_dir}" >&2
  exit 1
fi

rotate_logs() {
  local size index
  [[ -f "${LOG_FILE}" ]] || return 0

  size="$(stat -c '%s' "${LOG_FILE}" 2>/dev/null || printf '0')"
  (( size >= MAX_LOG_BYTES )) || return 0

  rm -f -- "${LOG_FILE}.${MAX_ARCHIVES}"
  for ((index = MAX_ARCHIVES - 1; index >= 1; index--)); do
    if [[ -f "${LOG_FILE}.${index}" ]]; then
      mv -- "${LOG_FILE}.${index}" "${LOG_FILE}.$((index + 1))"
    fi
  done
  mv -- "${LOG_FILE}" "${LOG_FILE}.1"
}

rotate_logs
umask 0007
timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%
'   "${timestamp}" "${PID}" "${CPU_USAGE}" "${MEM_USAGE}" "${DISK_USED}" >> "${LOG_FILE}"

echo
echo "[INFO] Log appended: ${LOG_FILE}"
