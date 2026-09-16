#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run as root: sudo CONFIRM_UFW_RESET=YES ./setup.sh" >&2
  exit 1
fi
if [[ "${CONFIRM_UFW_RESET:-}" != "YES" ]]; then
  echo "This setup resets UFW rules and changes the SSH port." >&2
  echo "Use a VM/console and rerun with CONFIRM_UFW_RESET=YES after reviewing README.md." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AGENT_HOME="/home/agent-admin/agent-app"
AGENT_PORT="15034"
AGENT_UPLOAD_DIR="${AGENT_HOME}/upload_files"
AGENT_KEY_PATH="${AGENT_HOME}/api_keys/t_secret.key"
AGENT_LOG_DIR="/var/log/agent-app"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server ufw acl python3 iproute2 util-linux cron

for group in agent-common agent-core; do
  getent group "${group}" >/dev/null || groupadd "${group}"
done

create_user() {
  local user="$1"
  if ! id "${user}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "${user}"
  fi
}

for user in agent-admin agent-dev agent-test; do
  create_user "${user}"
  usermod -aG agent-common "${user}"
done
usermod -aG agent-core agent-admin
usermod -aG agent-core agent-dev

install -d -o agent-admin -g agent-common -m 2770 "${AGENT_HOME}"
install -d -o agent-admin -g agent-common -m 2770 "${AGENT_UPLOAD_DIR}"
install -d -o agent-admin -g agent-core -m 2770 "${AGENT_HOME}/api_keys"
install -d -o agent-dev -g agent-core -m 2750 "${AGENT_HOME}/bin"
install -d -o agent-admin -g agent-core -m 2770 "${AGENT_LOG_DIR}"

setfacl -m u::rwx,g::rwx,g:agent-common:rwx,m::rwx,o::--- "${AGENT_UPLOAD_DIR}"
setfacl -d -m u::rwx,g::rwx,g:agent-common:rwx,m::rwx,o::--- "${AGENT_UPLOAD_DIR}"
setfacl -m u::rwx,g::rwx,g:agent-core:rwx,m::rwx,o::--- "${AGENT_HOME}/api_keys" "${AGENT_LOG_DIR}"
setfacl -d -m u::rwx,g::rwx,g:agent-core:rwx,m::rwx,o::--- "${AGENT_HOME}/api_keys" "${AGENT_LOG_DIR}"

printf '%s
' 'agent_api_key_test' > "${AGENT_KEY_PATH}"
chown agent-admin:agent-core "${AGENT_KEY_PATH}"
chmod 0660 "${AGENT_KEY_PATH}"

install -o agent-dev -g agent-core -m 0750 "${SCRIPT_DIR}/monitor.sh" "${AGENT_HOME}/bin/monitor.sh"
install -o agent-admin -g agent-core -m 0750 "${SCRIPT_DIR}/agent_app.py" "${AGENT_HOME}/agent_app.py"

cat > /etc/profile.d/agent-app.sh <<EOF
export AGENT_HOME="${AGENT_HOME}"
export AGENT_PORT="${AGENT_PORT}"
export AGENT_UPLOAD_DIR="${AGENT_UPLOAD_DIR}"
export AGENT_KEY_PATH="${AGENT_KEY_PATH}"
export AGENT_LOG_DIR="${AGENT_LOG_DIR}"
EOF
chmod 0644 /etc/profile.d/agent-app.sh

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-agent-app.conf <<'EOF'
Port 20022
PermitRootLogin no
EOF
/usr/sbin/sshd -t

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp comment 'SSH'
ufw allow 15034/tcp comment 'Agent app'
ufw --force enable

cat > /etc/systemd/system/agent-app.service <<EOF
[Unit]
Description=Agent training application
After=network.target
Wants=network.target

[Service]
Type=simple
User=agent-admin
Group=agent-core
Environment=PYTHONUNBUFFERED=1
Environment=AGENT_HOME=${AGENT_HOME}
Environment=AGENT_PORT=${AGENT_PORT}
Environment=AGENT_UPLOAD_DIR=${AGENT_UPLOAD_DIR}
Environment=AGENT_KEY_PATH=${AGENT_KEY_PATH}
Environment=AGENT_LOG_DIR=${AGENT_LOG_DIR}
ExecStart=/usr/bin/python3 ${AGENT_HOME}/agent_app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cron_line="* * * * * AGENT_PORT=${AGENT_PORT} ${AGENT_HOME}/bin/monitor.sh >/dev/null 2>&1"
current_cron="$(crontab -u agent-admin -l 2>/dev/null || true)"
filtered_cron="$(printf '%s
' "${current_cron}" | grep -vF "${AGENT_HOME}/bin/monitor.sh" || true)"
{
  printf '%s
' "${filtered_cron}"
  printf '%s
' "${cron_line}"
} | sed '/^[[:space:]]*$/d' | crontab -u agent-admin -

systemctl daemon-reload
systemctl enable --now cron
systemctl enable --now agent-app
systemctl restart ssh

echo
echo "Setup complete. Verify with:"
echo "  sshd -T | grep -E '^(port|permitrootlogin)'"
echo "  ufw status numbered"
echo "  id agent-admin; id agent-dev; id agent-test"
echo "  getfacl ${AGENT_UPLOAD_DIR} ${AGENT_HOME}/api_keys ${AGENT_LOG_DIR}"
echo "  journalctl -u agent-app -n 30 --no-pager"
echo "  ss -ltnp | grep ':${AGENT_PORT}'"
echo "  crontab -u agent-admin -l"
echo "  tail -n 5 ${AGENT_LOG_DIR}/monitor.log"
