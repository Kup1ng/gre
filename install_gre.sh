#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEFAULT_KEY="2749365187"
DEFAULT_MTU="1472"

# Status ping settings
PING_COUNT=100
PING_INTERVAL="0.1"
PING_TIMEOUT="1"
PING_DEADLINE="12"

die() { echo "Error: $*" >&2; exit 1; }

is_num_1_255() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 255 ))
}

# Fix: detect existing links even when shown as gre-ir-7@NONE
tunnel_num_exists() {
  local n="$1"

  if [[ -f "/etc/systemd/system/gre-ir-${n}.service" || -f "/etc/systemd/system/gre-kh-${n}.service" ]]; then
    return 0
  fi

  if /sbin/ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -qE "^gre-(ir|kh)-${n}(@|$)"; then
    return 0
  fi

  if /sbin/ip tunnel show 2>/dev/null | grep -qE "^(gre-ir-${n}|gre-kh-${n}):"; then
    return 0
  fi

  return 1
}

extract_local_remote_from_unit() {
  local unit_file="$1"
  local line local_ip remote_ip

  line=$(grep -E '^ExecStart=/sbin/ip tunnel add ' "$unit_file" 2>/dev/null | head -n1 || true)
  [[ -n "$line" ]] || return 1

  local_ip=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="local") {print $(i+1); exit}}')
  remote_ip=$(echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="remote") {print $(i+1); exit}}')

  [[ -n "${local_ip:-}" && -n "${remote_ip:-}" ]] || return 1
  echo "$local_ip $remote_ip"
  return 0
}

find_duplicate_endpoints() {
  local ip_iran="$1"
  local ip_foreign="$2"

  shopt -s nullglob
  local f pair local_ip remote_ip

  for f in /etc/systemd/system/gre-ir-*.service /etc/systemd/system/gre-kh-*.service; do
    [[ -f "$f" ]] || continue
    pair=$(extract_local_remote_from_unit "$f" || true)
    [[ -n "$pair" ]] || continue

    local_ip="${pair%% *}"
    remote_ip="${pair##* }"

    if { [[ "$local_ip" == "$ip_iran" && "$remote_ip" == "$ip_foreign" ]] || \
         [[ "$local_ip" == "$ip_foreign" && "$remote_ip" == "$ip_iran" ]]; }; then
      basename "$f" | sed -E 's/^gre-(ir|kh)-([0-9]+)\.service$/\2/'
      return 0
    fi
  done

  return 1
}

preinstall_conflict_checks() {
  local tunnel_num="$1"
  local ip_iran="$2"
  local ip_foreign="$3"

  if tunnel_num_exists "$tunnel_num"; then
    die "Tunnel number ${tunnel_num} already exists. Aborting to avoid conflicts."
  fi

  local dup_num
  if dup_num=$(find_duplicate_endpoints "$ip_iran" "$ip_foreign"); then
    die "Duplicate endpoints detected. You are trying to create the same Iran/Foreign IP pair as tunnel number ${dup_num}. Aborting."
  fi
}

remove_one_tunnel() {
  local tunnel_num="$1"
  echo "[*] Removing GRE tunnel(s) for tunnel number: $tunnel_num"

  for side in ir kh; do
    local gre_name="gre-${side}-${tunnel_num}"
    local unit_file="/etc/systemd/system/${gre_name}.service"

    if [[ -f "$unit_file" ]]; then
      echo "[*] Removing service: $gre_name"
      systemctl stop "$gre_name" 2>/dev/null || true
      systemctl disable "$gre_name" 2>/dev/null || true
      rm -f "$unit_file"
    fi

    local keepalive_name="gre-keepalive-${side}-${tunnel_num}"
    local keepalive_unit="/etc/systemd/system/${keepalive_name}.service"

    if [[ -f "$keepalive_unit" ]]; then
      echo "[*] Removing KeepAlive service: $keepalive_name"
      systemctl stop "$keepalive_name" 2>/dev/null || true
      systemctl disable "$keepalive_name" 2>/dev/null || true
      rm -f "$keepalive_unit"
    fi
  done

  /sbin/ip link set dev "gre-ir-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-ir-${tunnel_num}" 2>/dev/null || true
  /sbin/ip link set dev "gre-kh-${tunnel_num}" down 2>/dev/null || true
  /sbin/ip tunnel del "gre-kh-${tunnel_num}" 2>/dev/null || true
}

remove_all() {
  echo "[*] Removing ALL GRE tunnels/services created by this script..."
  shopt -s nullglob

  local units=(/etc/systemd/system/gre-ir-*.service /etc/systemd/system/gre-kh-*.service)
  local ka_units=(/etc/systemd/system/gre-keepalive-ir-*.service /etc/systemd/system/gre-keepalive-kh-*.service)

  for unit in "${units[@]}" "${ka_units[@]}"; do
    [[ -f "$unit" ]] || continue
    local name
    name=$(basename "$unit" .service)
    echo "[*] Removing service: $name"
    systemctl stop "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
    rm -f "$unit"
  done

  if command -v ip >/dev/null 2>&1; then
    while read -r line; do
      local tname
      tname=$(echo "$line" | awk -F: '{print $1}')
      if [[ "$tname" =~ ^gre-(ir|kh)-[0-9]+$ ]]; then
        echo "[*] Deleting leftover tunnel device: $tname"
        /sbin/ip link set dev "$tname" down 2>/dev/null || true
        /sbin/ip tunnel del "$tname" 2>/dev/null || true
      fi
    done < <(/sbin/ip tunnel show 2>/dev/null || true)
  fi
}

calc_peer_ip() {
  local local_ip="$1"
  if [[ "$local_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.1$ ]]; then
    echo "${BASH_REMATCH[1]}.2"
  elif [[ "$local_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.2$ ]]; then
    echo "${BASH_REMATCH[1]}.1"
  else
    echo ""
  fi
}

# Return integer loss percent (0-100). If unknown => 100.
ping_loss_pct() {
  local src_ip="$1"
  local dst_ip="$2"
  local out loss

  out=$(/bin/ping -c "$PING_COUNT" -i "$PING_INTERVAL" -W "$PING_TIMEOUT" -w "$PING_DEADLINE" -I "$src_ip" "$dst_ip" 2>/dev/null || true)

  loss=$(echo "$out" | awk -F',' '/packet loss/ {gsub(/%/,"",$3); gsub(/ /,"",$3); print $3}' | head -n1)
  if [[ -z "${loss:-}" ]]; then
    echo "100"
    return 0
  fi

  loss="${loss%%.*}"
  if ! [[ "$loss" =~ ^[0-9]+$ ]]; then
    echo "100"
    return 0
  fi

  (( loss < 0 )) && loss=0
  (( loss > 100 )) && loss=100
  echo "$loss"
}

status_ping_all() {
  shopt -s nullglob

  local ifaces=()
  local s
  while read -r s; do
    [[ -n "$s" ]] || continue
    s="${s%%@*}"
    ifaces+=("$s")
  done < <(
    /sbin/ip -o link show 2>/dev/null       | awk -F': ' '{print $2}'       | grep -E '^gre-(ir|kh)-[0-9]+'       | sort -u
  )

  if (( ${#ifaces[@]} == 0 )); then
    echo "No GRE interfaces found."
    exit 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir:-}"' EXIT

  for ifc in "${ifaces[@]}"; do
    (
      local tid local_tun_ip dst_ip link_line local_pub peer_pub
      local peer_loss dst_loss detail max_loss
      local peer_file dst_file row_file

      tid=$(echo "$ifc" | sed -E 's/^gre-(ir|kh)-([0-9]+)$/\2/')
      [[ -n "$tid" ]] || tid="$ifc"

      local_tun_ip=$(/sbin/ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
      if [[ -z "$local_tun_ip" ]]; then
        echo -e "${tid}\t-\t(100%)\t-\t(100%)\t${RED}DC${NC}" > "$tmpdir/row_${tid}"
        exit 0
      fi

      dst_ip=$(calc_peer_ip "$local_tun_ip")
      if [[ -z "$dst_ip" ]]; then
        echo -e "${tid}\t-\t(100%)\t-\t(100%)\t${RED}DC${NC}" > "$tmpdir/row_${tid}"
        exit 0
      fi

      link_line=$(/sbin/ip -d link show "$ifc" 2>/dev/null | awk '/link\/gre/ {print; exit}' || true)
      local_pub=$(echo "$link_line" | awk '{print $2}')
      peer_pub=$(echo "$link_line" | awk '{for (i=1;i<=NF;i++) if ($i=="peer") {print $(i+1); exit}}')

      peer_file="$tmpdir/.peer_${tid}"
      dst_file="$tmpdir/.dst_${tid}"
      row_file="$tmpdir/row_${tid}"

      if [[ -n "${local_pub:-}" && -n "${peer_pub:-}" ]]; then
        ping_loss_pct "$local_pub" "$peer_pub" > "$peer_file" &
      else
        peer_pub="-"
        echo "100" > "$peer_file" &
      fi

      ping_loss_pct "$local_tun_ip" "$dst_ip" > "$dst_file" &

      wait

      peer_loss=$(cat "$peer_file" 2>/dev/null || echo "100")
      dst_loss=$(cat "$dst_file" 2>/dev/null || echo "100")

      if (( peer_loss >= 100 || dst_loss >= 100 )); then
        detail="${RED}DC${NC}"
      else
        if (( peer_loss > 20 || dst_loss > 20 )); then
          max_loss=$peer_loss
          (( dst_loss > max_loss )) && max_loss=$dst_loss
          detail="${YELLOW}Warning (${max_loss}%)${NC}"
        else
          detail="${GREEN}Connected${NC}"
        fi
      fi

      echo -e "${tid}\t${peer_pub}\t(${peer_loss}%)\t${dst_ip}\t(${dst_loss}%)\t${detail}" > "$row_file"
    ) &
  done

  wait

  {
    for f in "$tmpdir"/row_*; do
      [[ -f "$f" ]] || continue
      cat "$f"
    done
  } | sort -t$'\t' -k1,1n | awk -F'\t' 'BEGIN{
      printf "%-6s %-16s %-7s %-16s %-7s %s\n","IFACE","PEER_IP","STAT","DST_IP","STAT","DETAIL"
      printf "%-6s %-16s %-7s %-16s %-7s %s\n","-----","---------------","-----","---------------","-----","-------------------------"
    }{
      printf "%-6s %-16s %-7s %-16s %-7s %s\n",$1,$2,$3,$4,$5,$6
    }'
}

install_flow() {
  local side_prefix="$1"   # ir or kh

  read -rp "Enter tunnel number (1-255): " tunnel_num
  is_num_1_255 "$tunnel_num" || die "Invalid tunnel number. Must be 1-255."

  read -rp "Enter Iran server IP: " ip_iran
  [[ -n "$ip_iran" ]] || die "Iran server IP is required."
  read -rp "Enter Foreign server IP: " ip_foreign
  [[ -n "$ip_foreign" ]] || die "Foreign server IP is required."

  preinstall_conflict_checks "$tunnel_num" "$ip_iran" "$ip_foreign"

  read -rp "Enter GRE key (1-4294967295) [${DEFAULT_KEY}]: " gre_key
  gre_key="${gre_key:-$DEFAULT_KEY}"
  if ! [[ "$gre_key" =~ ^[0-9]+$ ]] || (( 10#$gre_key < 1 || 10#$gre_key > 4294967295 )); then
    die "Invalid GRE key. Must be 1-4294967295."
  fi

  read -rp "Enter MTU [${DEFAULT_MTU}]: " mtu
  mtu="${mtu:-$DEFAULT_MTU}"
  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( 10#$mtu < 576 || 10#$mtu > 9000 )); then
    die "Invalid MTU. Use a number between 576 and 9000."
  fi

    echo "Select tunnel IP range:"
    echo "  1) Private (172.17.<tunnel>.0/30)"
    echo "  2) Public"
    read -rp "Choice [1-2]: " range_choice
    [[ "$range_choice" == "1" || "$range_choice" == "2" ]] || die "Invalid range choice."

    local base_prefix=""
    if [[ "$range_choice" == "1" ]]; then
      base_prefix="172.17"
    else
      # Public prefixes list (extendable)
      local -a pub_prefixes=("109.194" "87.107")
      echo "Select public range:"
      local i
      for i in "${!pub_prefixes[@]}"; do
        echo "  $((i+1))) ${pub_prefixes[$i]}.<tunnel>.0/30"
      done
      read -rp "Choice [1-${#pub_prefixes[@]}]: " pub_choice
      [[ "$pub_choice" =~ ^[0-9]+$ ]] || die "Invalid public range choice."
      (( pub_choice >= 1 && pub_choice <= ${#pub_prefixes[@]} )) || die "Invalid public range choice."
      base_prefix="${pub_prefixes[$((pub_choice-1))]}"
    fi

  local gre_name="gre-${side_prefix}-${tunnel_num}"
  local unit_file="/etc/systemd/system/${gre_name}.service"

  local ip_local ip_remote tun_ip ping_ip source_ip
  if [[ "$side_prefix" == "ir" ]]; then
    ip_local="$ip_iran"
    ip_remote="$ip_foreign"
    tun_ip="${base_prefix}.${tunnel_num}.1/30"
    ping_ip="${base_prefix}.${tunnel_num}.2"
    source_ip="${base_prefix}.${tunnel_num}.1"
  else
    ip_local="$ip_foreign"
    ip_remote="$ip_iran"
    tun_ip="${base_prefix}.${tunnel_num}.2/30"
    ping_ip="${base_prefix}.${tunnel_num}.1"
    source_ip="${base_prefix}.${tunnel_num}.2"
  fi

  local keepalive_name="gre-keepalive-${side_prefix}-${tunnel_num}"
  local keepalive_unit="/etc/systemd/system/${keepalive_name}.service"

  echo "[*] Installing GRE tunnel: $gre_name"

  cat > "$unit_file" <<EOF
[Unit]
Description=GRE Tunnel $gre_name
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip tunnel add $gre_name mode gre local $ip_local remote $ip_remote ttl 255 key $gre_key
ExecStartPost=/sbin/ip addr add $tun_ip dev $gre_name
ExecStartPost=/sbin/ip link set dev $gre_name mtu $mtu
ExecStartPost=/sbin/ip link set dev $gre_name up
ExecStop=/sbin/ip link set dev $gre_name down
ExecStop=/sbin/ip tunnel del $gre_name
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  cat > "$keepalive_unit" <<EOF
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
}

main_menu() {
  echo "Select an option:"
  echo "  1) Install (Iran side)"
  echo "  2) Install (Foreign side)"
  echo "  3) Remove"
  echo "  4) Status"
  read -rp "Choice [1-4]: " choice
  echo
  case "$choice" in
    1) install_flow "ir" ;;
    2) install_flow "kh" ;;
    3)
      read -rp "Enter tunnel number(s) (e.g. 1,3,7) or '@all': " tunnel_sel
      if [[ "$tunnel_sel" == "@all" || "$tunnel_sel" == "all" ]]; then
        remove_all
        systemctl daemon-reload
        echo "[+] Done. All matching GRE services and tunnels removed (best effort)."
        exit 0
      fi

      IFS=',' read -r -a nums <<< "$tunnel_sel"
      (( ${#nums[@]} > 0 )) || die "No tunnel numbers provided."

      declare -A seen=()
      for n in "${nums[@]}"; do
        n="${n//[[:space:]]/}"
        is_num_1_255 "$n" || die "Invalid tunnel number: '$n' (must be 1-255)"
        seen["$n"]=1
      done

      for n in "${!seen[@]}"; do
        remove_one_tunnel "$n"
      done

      systemctl daemon-reload
      echo "[+] Selected tunnel(s) removed (if existed)."
      ;;
    4) status_ping_all ;;
    *) die "Invalid choice. Use 1-4." ;;
  esac
}

main_menu
