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

read -rp "Enter Iran server IP:     " IP_IR
read -rp "Enter Foreign server IP:  " IP_KH
read -rp "Tunnel instance number (1-250): " TUN_ID

if ! [[ "$TUN_ID" =~ ^[0-9]+$ ]] || (( TUN_ID < 1 || TUN_ID > 250 )); then
  echo "Tunnel ID must be an integer between 1 and 250." >&2 ; exit 1
fi

# ---------- dynamic parameters ----------
SUBNET="172.17.${TUN_ID}"
if [[ "$LOCATION" == "ir" ]]; then
  GRE_IF="gre-ir${TUN_ID}"
  MY_IP="${SUBNET}.2/30"
  PEER_IP="${SUBNET}.1"
else
  GRE_IF="gre-kh${TUN_ID}"
  MY_IP="${SUBNET}.1/30"
  PEER_IP="${SUBNET}.2"
fi

GRE_SCRIPT="/etc/gre${TUN_ID}.local"
GRE_SERVICE="gre-local${TUN_ID}.service"
WATCHDOG_SCRIPT="/usr/local/sbin/gre_watchdog${TUN_ID}.sh"
WATCHDOG_SERVICE="gre-watchdog${TUN_ID}.service"

# ---------- create gre${TUN_ID}.local ----------
cat > "$GRE_SCRIPT" <<EOF
#!/bin/bash
ip tunnel add ${GRE_IF} mode gre local ${IP_IR} remote ${IP_KH} ttl 255
ip addr add ${MY_IP} dev ${GRE_IF}
ip link set dev ${GRE_IF} mtu 1456
ip link set dev ${GRE_IF} up
exit 0
EOF
chmod +x "$GRE_SCRIPT"

# ---------- systemd service for tunnel ----------
cat > /etc/systemd/system/${GRE_SERVICE} <<EOF
[Unit]
Description=/etc/gre${TUN_ID}.local Compatibility
ConditionPathExists=${GRE_SCRIPT}
After=network.target

[Service]
Type=forking
ExecStart=${GRE_SCRIPT} start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOF

# ---------- watchdog script ----------
cat > "$WATCHDOG_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

GRE_IF="${GRE_IF}"
PEER_IP="${PEER_IP}"
LOCATION="${LOCATION}"
PING_INTERVAL=1
MAX_LOSS=10
RECREATE_DELAY=30
SCRIPT_RECREATE="${GRE_SCRIPT}"
AUTO_RESTART_IR="/usr/bin/auto_restart_cronjob.sh"

loss=0
while true; do
  if ping -c1 -W1 "\$PEER_IP" >/dev/null 2>&1; then
    loss=0
  else
    ((loss++))
  fi

  if (( loss >= MAX_LOSS )); then
    echo "\$(date '+%F %T') GRE \$GRE_IF down – recreating..."
    ip link delete "\$GRE_IF" || true
    [[ "\$LOCATION" == "ir" ]] && "\$AUTO_RESTART_IR" || true
    sleep "\$RECREATE_DELAY"
    bash "\$SCRIPT_RECREATE" start
    loss=0
  fi
  sleep "\$PING_INTERVAL"
done
EOF
chmod +x "$WATCHDOG_SCRIPT"

# ---------- watchdog systemd unit ----------
cat > /etc/systemd/system/${WATCHDOG_SERVICE} <<EOF
[Unit]
Description=GRE tunnel watchdog (${GRE_IF})
After=network.target ${GRE_SERVICE}
Wants=${GRE_SERVICE}

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------- enable services ----------
systemctl daemon-reload
systemctl enable --now ${GRE_SERVICE}
systemctl enable --now ${WATCHDOG_SERVICE}

echo "GRE tunnel '${GRE_IF}' (ID ${TUN_ID}) is up with watchdog."
