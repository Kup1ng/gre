#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root or with sudo." >&2
  exit 1
fi

read -rp "Is this the IRAN or FOREIGN server? [ir/kh]: " LOCATION
LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')
if [[ "$LOCATION" != "ir" && "$LOCATION" != "kh" ]]; then
  echo "Only 'ir' or 'kh' is accepted." >&2 ; exit 1
fi

read -rp "Enter Iran server IP:  " IP_IR
read -rp "Enter Foreign server IP:  " IP_KH

# Create gre.local
GRE_SCRIPT="/etc/gre.local"
if [[ "$LOCATION" == "ir" ]]; then
  cat > "$GRE_SCRIPT" <<EOF
#!/bin/bash
ip tunnel add gre-ir mode gre local ${IP_IR} remote ${IP_KH} ttl 255
ip addr add 172.17.1.2/30 dev gre-ir
ip link set dev gre-ir mtu 1456
ip link set dev gre-ir up
exit 0
EOF
else
  cat > "$GRE_SCRIPT" <<EOF
#!/bin/bash
ip tunnel add gre-kh mode gre local ${IP_KH} remote ${IP_IR} ttl 255
ip addr add 172.17.1.1/30 dev gre-kh
ip link set dev gre-kh mtu 1456
ip link set dev gre-kh up
exit 0
EOF
fi
chmod +x "$GRE_SCRIPT"

echo "$LOCATION" > /etc/gre_location.flag
chmod 644 /etc/gre_location.flag

# gre-local.service
cat > /etc/systemd/system/gre-local.service <<'EOF'
[Unit]
Description=/etc/gre.local Compatibility
ConditionPathExists=/etc/gre.local
After=network.target

[Service]
Type=forking
ExecStart=/etc/gre.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOF

# Watchdog script
cat > /usr/local/sbin/gre_watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCATION=$(cat /etc/gre_location.flag 2>/dev/null || echo "unknown")
PING_INTERVAL=1
MAX_LOSS=10
RECREATE_DELAY=30
SCRIPT_RECREATE="/etc/gre.local"
AUTO_RESTART_IR="/usr/bin/auto_restart_cronjob.sh"

if [[ "$LOCATION" == "ir" ]]; then
  GRE_NAME="gre-ir"
  PEER_IP="172.17.1.1"
elif [[ "$LOCATION" == "kh" ]]; then
  GRE_NAME="gre-kh"
  PEER_IP="172.17.1.2"
else
  echo "Unknown location. Exiting."
  exit 1
fi

loss=0
while true; do
  if ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1; then
    loss=0
  else
    ((loss++))
  fi

  if (( loss >= MAX_LOSS )); then
    echo "$(date '+%F %T') GRE down – recreating..."
    ip link delete "$GRE_NAME" || true
    [[ "$LOCATION" == "ir" ]] && "$AUTO_RESTART_IR" || true
    sleep "$RECREATE_DELAY"
    bash "$SCRIPT_RECREATE" start
    loss=0
  fi
  sleep "$PING_INTERVAL"
done
EOF
chmod +x /usr/local/sbin/gre_watchdog.sh

# gre-watchdog.service
cat > /etc/systemd/system/gre-watchdog.service <<'EOF'
[Unit]
Description=GRE tunnel watchdog
After=network.target gre-local.service
Wants=gre-local.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/gre_watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable services
systemctl daemon-reload
systemctl enable --now gre-local
systemctl enable --now gre-watchdog

echo "GRE tunnel setup and watchdog started successfully."
