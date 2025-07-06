#!/usr/bin/env bash
# install_gre.sh – یک‌جا همه‌چیز را بساز و فعال کن
set -euo pipefail

# ---------- بررسی دسترسی ----------
if [[ $EUID -ne 0 ]]; then
  echo "این اسکریپت باید با کاربر root اجرا شود (یا sudo)." >&2
  exit 1
fi

# ---------- ورودی کاربر ----------
read -rp "این سرور «ایران» است یا «خارج»؟ [ir/kh]: " LOCATION
LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')
if [[ "$LOCATION" != "ir" && "$LOCATION" != "kh" ]]; then
  echo "فقط ir یا kh مجاز است!" >&2 ; exit 1
fi

read -rp "آدرس IP سرور ایران:  " IP_IR
read -rp "آدرس IP سرور خارج:   " IP_KH

# ---------- ساخت فایل /etc/gre.local ----------
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

# ---------- ذخیره موقعیت برای واچ‌داگ ----------
echo "$LOCATION" > /etc/gre_location.flag
chmod 644 /etc/gre_location.flag

# ---------- یونیت gre-local ----------
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

# ---------- اسکریپت پایش ----------
cat > /usr/local/sbin/gre_watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCATION=$(cat /etc/gre_location.flag 2>/dev/null || echo "unknown")
PING_INTERVAL=1      # ثانیه
MAX_LOSS=10          # چند ثانیه قطع متوالی
RECREATE_DELAY=30    # ثانیه
SCRIPT_RECREATE="/etc/gre.local"
AUTO_RESTART_IR="/usr/bin/auto_restart_cronjob.sh"

if [[ "$LOCATION" == "ir" ]]; then
  GRE_NAME="gre-ir"
  PEER_IP="172.17.1.1"
elif [[ "$LOCATION" == "kh" ]]; then
  GRE_NAME="gre-kh"
  PEER_IP="172.17.1.2"
else
  echo "مکان سرور مشخص نیست!" ; exit 1
fi

loss=0
while true; do
  if ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1; then
    loss=0
  else
    ((loss++))
  fi

  if (( loss >= MAX_LOSS )); then
    echo "$(date '+%F %T')  GRE down – recreating..."
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

# ---------- یونیت واچ‌داگ ----------
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

# ---------- فعال‌سازی سرویس‌ها ----------
systemctl daemon-reload
systemctl enable --now gre-local
systemctl enable --now gre-watchdog

echo -e "\n✅ همه چیز انجام شد! تونل فعال است و واچ‌داگ در حال پایش مداوم می‌باشد."
