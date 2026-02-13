#!/bin/bash
set -e

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

    # 1) Stop/disable/remove all matching systemd unit files
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

    # 2) Best-effort cleanup of leftover ip tunnels that match our naming
    #    (in case unit files are gone or services weren't running)
    if command -v ip >/dev/null 2>&1; then
      while read -r line; do
        # Example line: gre-ir-10: gre/ip  remote ...
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

  # single tunnel number removal (old behavior)
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

  # best-effort delete tunnel device too
  /sbin/ip link set dev "gre-ir-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-ir-${tunnel_num}" 2>/dev/null || true
  /sbin/ip link set dev "gre-kh-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-kh-${tunnel_num}" 2>/dev/null || true

  systemctl daemon-reload
  echo "[+] GRE tunnel(s) with number $tunnel_num removed (if existed)."
  exit 0
fi

# ===== install flow (unchanged) =====

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
ping_ip=$( [[ "$is_iran" == "yes" ]] && echo "172.17.${tunnel_num}.2" || echo "172.17.${tunnel_num}.1" )
source_ip=$( [[ "$is_iran" == "yes" ]] && echo "172.17.${tunnel_num}.1" || echo "172.17.${tunnel_num}.2" )

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

cat <<EOF > "$keepalive_unit"
[Unit]
Description=GRE KeepAlive $keepalive_name
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/ping -I $source_ip -O -i 1 $ping_ip
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
echo "[+] KeepAlive service $keepalive_name installed (ping $ping_ip)."
