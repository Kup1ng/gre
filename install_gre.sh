#!/bin/bash
set -e

# ---------- deps ----------
ensure_hping3() {
  if command -v hping3 >/dev/null 2>&1; then
    return 0
  fi

  echo "[*] hping3 not found. Installing..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y hping3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y hping3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y hping3
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm hping3
  else
    echo "[!] No supported package manager found. Please install hping3 manually."
    exit 1
  fi

  command -v hping3 >/dev/null 2>&1 || { echo "[!] hping3 install failed."; exit 1; }
  echo "[+] hping3 installed."
}

HPING3_BIN="$(command -v hping3 2>/dev/null || true)"
# fallback common paths for embedding in systemd unit (in case PATH differs)
if [[ -z "$HPING3_BIN" ]]; then
  for p in /usr/sbin/hping3 /usr/bin/hping3 /sbin/hping3 /bin/hping3; do
    [[ -x "$p" ]] && HPING3_BIN="$p" && break
  done
fi

read -p "Do you want to install, remove or check status of tunnels? (install/remove/status): " action
if [[ "$action" != "install" && "$action" != "remove" && "$action" != "status" ]]; then
  echo "Invalid action. Choose 'install', 'remove' or 'status'."
  exit 1
fi

if [[ "$action" == "status" ]]; then
  echo "==== GRE Tunnel Status (tunnel services) ===="
  for service in /etc/systemd/system/gre-*-*.service; do
    [[ -e "$service" ]] || continue
    service_name=$(basename "$service" .service)
    tunnel_num=$(echo "$service_name" | grep -oP '[0-9]+$' || true)
    status=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
    echo "Tunnel ${tunnel_num:-?} ($service_name): $status"
  done

  echo
  echo "==== GRE KeepAlive Status ===="
  for service in /etc/systemd/system/gre-keepalive-*-*.service; do
    [[ -e "$service" ]] || continue
    service_name=$(basename "$service" .service)
    tunnel_num=$(echo "$service_name" | grep -oP '[0-9]+$' || true)
    status=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
    echo "KeepAlive ${tunnel_num:-?} ($service_name): $status"
  done
  exit 0
fi

if [[ "$action" == "remove" ]]; then
  read -p "Enter tunnel number (1-255) or '@all' to remove everything: " tunnel_sel

  if [[ "$tunnel_sel" == "@all" || "$tunnel_sel" == "all" ]]; then
    echo "[*] Removing ALL GRE tunnels/services created by this script..."

    shopt -s nullglob
    units=(/etc/systemd/system/gre-ir-*.service /etc/systemd/system/gre-kh-*.service)
    ka_units=(/etc/systemd/system/gre-keepalive-ir-*.service /etc/systemd/system/gre-keepalive-kh-*.service)

    for unit in "${units[@]}" "${ka_units[@]}"; do
      [[ -f "$unit" ]] || continue
      name=$(basename "$unit" .service)
      echo "[*] Removing service: $name"
      systemctl stop "$name" 2>/dev/null || true
      systemctl disable "$name" 2>/dev/null || true
      rm -f "$unit"
    done

    if command -v ip >/dev/null 2>&1; then
      while read -r line; do
        tname=$(echo "$line" | awk -F: '{print $1}')
        if [[ "$tname" =~ ^gre-(ir|kh)-[0-9]+$ ]]; then
          echo "[*] Deleting leftover tunnel device: $tname"
          /sbin/ip link set dev "$tname" down 2>/dev/null || true
          /sbin/ip tunnel del "$tname" 2>/dev/null || true
        fi
      done < <(/sbin/ip tunnel show 2>/dev/null || true)
    fi

    systemctl daemon-reload
    echo "[+] Done. All matching GRE services and tunnels removed (best effort)."
    exit 0
  fi

  tunnel_num="$tunnel_sel"
  if ! [[ "$tunnel_num" =~ ^[0-9]+$ ]] || ((tunnel_num < 1 || tunnel_num > 255)); then
    echo "Invalid tunnel number. Must be between 1 and 255, or use '@all'."
    exit 1
  fi

  echo "[*] Removing GRE tunnel(s) for tunnel number: $tunnel_num"

  for side in ir kh; do
    gre_name="gre-${side}-${tunnel_num}"
    unit_file="/etc/systemd/system/${gre_name}.service"

    if [[ -f "$unit_file" ]]; then
      echo "[*] Found service: $gre_name. Stopping and removing..."
      systemctl stop "$gre_name" || true
      systemctl disable "$gre_name" || true
      rm -f "$unit_file"
    fi

    keepalive_name="gre-keepalive-${side}-${tunnel_num}"
    keepalive_unit="/etc/systemd/system/${keepalive_name}.service"

    if [[ -f "$keepalive_unit" ]]; then
      echo "[*] Found KeepAlive service: $keepalive_name. Stopping and removing..."
      systemctl stop "$keepalive_name" || true
      systemctl disable "$keepalive_name" || true
      rm -f "$keepalive_unit"
    fi
  done

  /sbin/ip link set dev "gre-ir-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-ir-${tunnel_num}" 2>/dev/null || true
  /sbin/ip link set dev "gre-kh-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-kh-${tunnel_num}" 2>/dev/null || true

  systemctl daemon-reload
  echo "[+] GRE tunnel(s) with number $tunnel_num removed (if existed)."
  exit 0
fi

# ===== install flow =====
# make sure we can run keepalive via hping3
ensure_hping3
HPING3_BIN="$(command -v hping3)"
echo "[*] Using hping3: $HPING3_BIN"

read -p "Enter tunnel number (1-255): " tunnel_num
if ! [[ "$tunnel_num" =~ ^[0-9]+$ ]] || ((tunnel_num < 1 || tunnel_num > 255)); then
  echo "Invalid tunnel number. Must be between 1 and 255."
  exit 1
fi

read -p "Is this server located in Iran? (yes/no): " is_iran
if [[ "$is_iran" != "yes" && "$is_iran" != "no" ]]; then
  echo "Invalid input for server location."
  exit 1
fi

read -p "Enter Iran server IP: " ip_iran
read -p "Enter Foreign server IP: " ip_foreign
read -p "Enter GRE key (1-4294967295): " gre_key

if ! [[ "$gre_key" =~ ^[0-9]+$ ]] || ((gre_key < 1 || gre_key > 4294967295)); then
  echo "Invalid GRE key. Must be between 1 and 4294967295."
  exit 1
fi

side_prefix=$( [[ "$is_iran" == "yes" ]] && echo "ir" || echo "kh" )
gre_name="gre-${side_prefix}-${tunnel_num}"
ip_local=$( [[ "$is_iran" == "yes" ]] && echo "$ip_iran" || echo "$ip_foreign" )
ip_remote=$( [[ "$is_iran" == "yes" ]] && echo "$ip_foreign" || echo "$ip_iran" )
tun_ip=$( [[ "$is_iran" == "yes" ]] && echo "172.17.${tunnel_num}.1/30" || echo "172.17.${tunnel_num}.2/30" )
unit_file="/etc/systemd/system/${gre_name}.service"

keepalive_name="gre-keepalive-${side_prefix}-${tunnel_num}"
keepalive_unit="/etc/systemd/system/${keepalive_name}.service"

# target IP on the GRE /30
ping_ip=$( [[ "$is_iran" == "yes" ]] && echo "172.17.${tunnel_num}.2" || echo "172.17.${tunnel_num}.1" )

echo "[*] Installing GRE tunnel: $gre_name"

cat <<EOF > "$unit_file"
[Unit]
Description=GRE Tunnel $gre_name
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add $gre_name mode gre local $ip_local remote $ip_remote ttl 255 key $gre_key
ExecStartPost=/sbin/ip addr add $tun_ip dev $gre_name
ExecStartPost=/sbin/ip link set dev $gre_name mtu 1472
ExecStartPost=/sbin/ip link set dev $gre_name up
ExecStop=/sbin/ip link set dev $gre_name down
ExecStop=/sbin/ip tunnel del $gre_name
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# KeepAlive via hping3 TCP/22, 1 packet per second, bound to GRE interface
# -I: choose interface (so source uses the GRE address)
# -S: SYN packets
# -p 22: dest port 22
# -i u1000000: 1s interval (microseconds form)  :contentReference[oaicite:3]{index=3}
cat <<EOF > "$keepalive_unit"
[Unit]
Description=GRE KeepAlive $keepalive_name
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$HPING3_BIN -S -p 22 -I $gre_name -i u1000000 $ping_ip
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now "$gre_name"
systemctl enable --now "$keepalive_name"

echo "[+] Tunnel $gre_name installed and active."
echo "[+] KeepAlive service $keepalive_name installed (hping3 TCP/22 -> $ping_ip via $gre_name)."
