#!/usr/bin/env bash
# =============================================================
#  GRE over IPsec Tunnel Manager
#  Version: 2.0.0
# =============================================================
set -uo pipefail

VERSION="2.0.0"
CONF_DIR="/etc/gre-ipsec"
CONF_FILE="$CONF_DIR/tunnel.conf"
UP_SH="$CONF_DIR/up.sh"
DOWN_SH="$CONF_DIR/down.sh"
SERVICE_NAME="gre-ipsec.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
IPSEC_CONF="/etc/ipsec.d/gre-ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.d/gre-ipsec.secrets"
SWANCTL_CONF="/etc/swanctl/conf.d/gre-ipsec.conf"
CONN_NAME="gre-ipsec"

# ---------- palette (256-color) ----------
C1=$'\033[38;5;143m'   # olive green
C2=$'\033[38;5;217m'   # pale pink
C3=$'\033[38;5;138m'   # rosy brown
C4=$'\033[38;5;137m'   # chocolate
C5=$'\033[38;5;140m'   # pale purple
C6=$'\033[38;5;80m'    # turquoise
C7=$'\033[38;5;110m'   # pale blue
C8=$'\033[38;5;187m'   # pale khaki
C9=$'\033[38;5;152m'   # pale cyan
C10=$'\033[38;5;180m'  # tan
C11=$'\033[38;5;146m'  # dusty lavender
WHT=$'\033[38;5;255m'
GRY=$'\033[38;5;245m'
RST=$'\033[0m'
# status colours only
BG_OK=$'\033[48;5;28;38;5;16m'
BG_ERR=$'\033[48;5;124;38;5;231m'
BG_WARN=$'\033[48;5;208;38;5;16m'
FG_OK=$'\033[38;5;40m'
FG_ERR=$'\033[38;5;196m'
FG_WARN=$'\033[38;5;214m'

# ---------- globals ----------
ROLE=""            # iran | kharej
LOCAL_PUB=""
REMOTE_PUB=""
TUN_LOCAL=""
TUN_REMOTE=""
PSK=""
MTU=""
IF_NAME="gre1"
BACKEND=""         # starter | swanctl
SWAN_SVC=""
NAT_MODE="0"
PRIV_IP=""
BOXW=56

step() { echo -e "${GRY}>>${RST} ${C9}$1${RST}"; }
ok()   { echo -e "${BG_OK} OK ${RST} ${FG_OK}$1${RST}"; }
err()  { echo -e "${BG_ERR} ERROR ${RST} ${FG_ERR}$1${RST}"; }
warn() { echo -e "${BG_WARN} WARN ${RST} ${FG_WARN}$1${RST}"; }
line() { echo -e "${GRY}---------------------------------------------------------------${RST}"; }
pause(){ echo; read -rp "$(echo -e "${GRY}Press Enter to continue...${RST}")" _; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi
}

put_center() {
  # $1 = plain text (length used for padding), $2 = ansi prefix
  local text="$1" pre="${2:-}" width pad
  width="$(tput cols 2>/dev/null || echo 80)"
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%b%s%b\n" "$pad" "" "$pre" "$text" "$RST"
}

green_box_line() { put_center "$(printf ' %-*s' "$BOXW" "$1")" "$BG_OK"; }

header() {
  clear
  echo -e "\033[38;5;80m ██████╗ ██████╗ ███████╗    ██╗██████╗ ███████╗███████╗ ██████╗${RST}"
  echo -e "\033[38;5;79m██╔════╝ ██╔══██╗██╔════╝    ██║██╔══██╗██╔════╝██╔════╝██╔════╝${RST}"
  echo -e "\033[38;5;78m██║  ███╗██████╔╝█████╗█████╗██║██████╔╝███████╗█████╗  ██║     ${RST}"
  echo -e "\033[38;5;44m██║   ██║██╔══██╗██╔══╝╚════╝██║██╔═══╝ ╚════██║██╔══╝  ██║     ${RST}"
  echo -e "\033[38;5;43m╚██████╔╝██║  ██║███████╗    ██║██║     ███████║███████╗╚██████╗${RST}"
  echo -e "\033[38;5;37m ╚═════╝ ╚═╝  ╚═╝╚══════╝    ╚═╝╚═╝     ╚══════╝╚══════╝ ╚═════╝${RST}"
  echo -e "${GRY}                 GRE over IPsec Tunnel Manager  v${VERSION}${RST}"
  echo
}

is_installed() { [[ -f "$CONF_FILE" && -f "$SERVICE_FILE" ]]; }

status_banner() {
  if is_installed; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    local st="inactive"
    systemctl is-active --quiet "$SERVICE_NAME" && st="active"
    echo -e "${BG_OK} INSTALLED ${RST}  ${GRY}role:${RST} ${WHT}${ROLE^^}${RST}  ${GRY}iface:${RST} ${WHT}${IF_NAME}${RST}  ${GRY}service:${RST} ${WHT}${st}${RST}"
  else
    echo -e "${BG_ERR} NOT INSTALLED ${RST}  ${GRY}no tunnel configured on this server${RST}"
  fi
  line
}

# ---------- validation (never aborts, always re-asks) ----------
valid_ip() {
  local ip="$1" o x
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra o <<< "$ip"
  for x in "${o[@]}"; do ((10#$x >= 0 && 10#$x <= 255)) || return 1; done
  return 0
}

ask_ip() {
  local prompt="$1" def="$2" varname="$3" input=""
  while true; do
    if [[ -n "$def" ]]; then
      read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
      input="${input:-$def}"
    else
      read -rp "$(echo -e "${C7}${prompt}${RST}: ")" input
    fi
    valid_ip "$input" && { printf -v "$varname" '%s' "$input"; return 0; }
    err "Invalid IPv4 address. Please try again."
  done
}

ask_num() {
  local prompt="$1" def="$2" min="$3" max="$4" varname="$5" input=""
  while true; do
    read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
    input="${input:-$def}"
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= min && input <= max)); then
      printf -v "$varname" '%s' "$input"; return 0
    fi
    err "Enter a number between $min and $max."
  done
}

ask_choice() {
  local prompt="$1" def="$2" varname="$3" input=""
  shift 3
  local opts=("$@") o
  while true; do
    read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
    input="${input:-$def}"
    for o in "${opts[@]}"; do
      [[ "$input" == "$o" ]] && { printf -v "$varname" '%s' "$input"; return 0; }
    done
    err "Invalid choice. Allowed: ${opts[*]}"
  done
}

# ---------- detection helpers ----------
detect_priv_ip() {
  ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'
}

detect_public_ip() {
  local ip=""
  ip="$(timeout 6 curl -s https://api.ipify.org 2>/dev/null)"
  [[ -z "$ip" ]] && ip="$(timeout 6 curl -s http://ip-api.com/line/?fields=query 2>/dev/null | tr -d '\r\n')"
  [[ -z "$ip" ]] && ip="$(detect_priv_ip)"
  echo "$ip"
}

geo_cc() {
  # returns 2-letter country code, empty on failure
  local ip="$1" cc=""
  cc="$(timeout 6 curl -s "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -dc 'A-Za-z')"
  [[ ${#cc} -ne 2 ]] && cc="$(timeout 6 curl -s "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -dc 'A-Za-z')"
  [[ ${#cc} -ne 2 ]] && cc="$(timeout 6 curl -s "https://ipwho.is/${ip}?fields=country_code" 2>/dev/null | tr -dc 'A-Za-z')"
  [[ ${#cc} -eq 2 ]] && echo "${cc^^}" || echo ""
}

label_for_ip() {
  # $1 = public ip, $2 = fallback label (IRAN|KHAREJ)
  local cc
  cc="$(geo_cc "$1")"
  if [[ "$cc" == "IR" ]]; then echo "IRAN"
  elif [[ -n "$cc" ]]; then echo "KHAREJ"
  else echo "$2"; fi
}

detect_backend() {
  SWAN_SVC=""; BACKEND=""
  if systemctl list-unit-files 2>/dev/null | grep -q '^strongswan-starter\.service'; then
    SWAN_SVC="strongswan-starter"; BACKEND="starter"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^strongswan\.service'; then
    SWAN_SVC="strongswan"
    if command -v swanctl >/dev/null 2>&1 && [[ -d /etc/swanctl ]]; then
      BACKEND="swanctl"
    else
      BACKEND="starter"
    fi
  elif command -v ipsec >/dev/null 2>&1; then
    BACKEND="starter"
  elif command -v swanctl >/dev/null 2>&1; then
    BACKEND="swanctl"
  fi
}

sa_established() {
  if [[ "$BACKEND" == "swanctl" ]]; then
    timeout 8 swanctl --list-sas 2>/dev/null | grep -q 'ESTABLISHED'
  else
    timeout 8 ipsec status 2>/dev/null | grep -q 'ESTABLISHED'
  fi
}

iface_up() { ip link show "$IF_NAME" 2>/dev/null | grep -q 'state UNKNOWN\|state UP'; }

ping_peer() {
  local count="${1:-3}"
  timeout $((count * 2 + 4)) ping -c "$count" -W 2 -I "$IF_NAME" "$TUN_REMOTE" >/dev/null 2>&1
}

# ---------- preflight ----------
preflight() {
  local fatal=0 virt=""

  step "Checking virtualization type"
  virt="$(systemd-detect-virt -c 2>/dev/null || echo none)"
  if [[ "$virt" =~ (lxc|openvz|docker|podman) ]]; then
    err "Container virtualization detected ($virt)."
    err "GRE tunnels and IPsec require a real kernel (KVM/Xen/bare metal)."
    fatal=1
  else
    ok "Virtualization: ${virt}"
  fi

  step "Checking GRE kernel support"
  modprobe ip_gre 2>/dev/null
  if [[ -d /sys/module/ip_gre ]] || ip tunnel show >/dev/null 2>&1; then
    ok "GRE kernel support available."
  else
    err "ip_gre kernel module is not available on this server."
    fatal=1
  fi

  step "Checking IPsec kernel support"
  modprobe af_key 2>/dev/null
  modprobe esp4 2>/dev/null
  modprobe xfrm_user 2>/dev/null
  if [[ -d /proc/sys/net/core/xfrm_acq_expires ]] || [[ -f /proc/net/xfrm_stat ]] || sysctl -n net.core.xfrm_acq_expires >/dev/null 2>&1; then
    ok "XFRM/IPsec kernel support available."
  else
    warn "Could not confirm XFRM support. IPsec may fail on this kernel."
  fi

  step "Checking UDP 500 / 4500"
  local busy=""
  if command -v ss >/dev/null 2>&1; then
    ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE ':500$'  && busy="500"
    ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE ':4500$' && busy="${busy:+$busy, }4500"
  fi
  if [[ -n "$busy" ]]; then
    warn "UDP port(s) $busy already bound. If not strongSwan, IPsec will fail."
  else
    ok "IKE ports are free."
  fi

  return $fatal
}

# ---------- dependencies ----------
install_deps() {
  step "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    timeout 180 apt-get update -qq >/dev/null 2>&1
    timeout 300 apt-get install -y -qq iproute2 iptables curl iputils-ping \
      strongswan strongswan-starter strongswan-swanctl libstrongswan-standard-plugins \
      libcharon-extra-plugins >/dev/null 2>&1
    if ! command -v ipsec >/dev/null 2>&1 && ! command -v swanctl >/dev/null 2>&1; then
      timeout 300 apt-get install -y -qq strongswan >/dev/null 2>&1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    timeout 300 dnf install -y -q iproute iptables curl iputils strongswan >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    timeout 300 yum install -y -q iproute iptables curl iputils strongswan >/dev/null 2>&1
  else
    warn "Unknown package manager. Install strongSwan manually."
  fi

  detect_backend
  if [[ -z "$BACKEND" ]]; then
    err "strongSwan was not installed. Install it manually and re-run."
    return 1
  fi
  ok "Dependencies ready. Backend: ${BACKEND}${SWAN_SVC:+ (${SWAN_SVC})}"
  return 0
}

# ---------- input gathering ----------
gather_inputs() {
  local detected role_in="" psk_in="" go=""
  detected="$(detect_public_ip)"
  PRIV_IP="$(detect_priv_ip)"

  echo -e "${C1}Server Role${RST}"
  echo -e "${C2}  1) IRAN     ${GRY}- tunnel IP 10.10.10.1${RST}"
  echo -e "${C3}  2) KHAREJ   ${GRY}- tunnel IP 10.10.10.2${RST}"
  ask_choice "Select role" "1" role_in "1" "2"
  [[ "$role_in" == "1" ]] && ROLE="iran" || ROLE="kharej"

  local def_local def_remote
  if [[ "$ROLE" == "iran" ]]; then
    def_local="10.10.10.1"; def_remote="10.10.10.2"
  else
    def_local="10.10.10.2"; def_remote="10.10.10.1"
  fi

  echo
  echo -e "${C4}Public Endpoints${RST}"
  ask_ip "This Server Public IP" "$detected" LOCAL_PUB
  while true; do
    ask_ip "Peer Server Public IP" "" REMOTE_PUB
    [[ "$REMOTE_PUB" != "$LOCAL_PUB" ]] && break
    err "Peer IP cannot be the same as this server IP."
  done

  if [[ -n "$PRIV_IP" && "$PRIV_IP" != "$LOCAL_PUB" ]]; then
    NAT_MODE="1"
    warn "NAT detected: interface IP is $PRIV_IP but public IP is $LOCAL_PUB."
    warn "NAT traversal (encapsulation) will be enabled automatically."
  else
    NAT_MODE="0"
  fi

  echo
  echo -e "${C5}Tunnel Addresses${RST}"
  ask_ip "This Side Tunnel IP" "$def_local" TUN_LOCAL
  while true; do
    ask_ip "Peer Side Tunnel IP" "$def_remote" TUN_REMOTE
    [[ "$TUN_REMOTE" != "$TUN_LOCAL" ]] && break
    err "Peer tunnel IP must differ from this side tunnel IP."
  done

  echo
  echo -e "${C6}Tunnel Options${RST}"
  ask_num "Tunnel MTU" "1400" 576 1500 MTU

  local def_psk
  def_psk="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)"
  while true; do
    read -rp "$(echo -e "${C8}Shared Secret (PSK)${RST} ${GRY}(${WHT}${def_psk}${GRY})${RST}: ")" psk_in
    psk_in="${psk_in:-$def_psk}"
    ((${#psk_in} >= 8)) && { PSK="$psk_in"; break; }
    err "PSK must be at least 8 characters."
  done

  echo
  line
  echo -e "${C9}Review${RST}"
  echo -e "${C1}  Role            ${WHT}${ROLE^^}${RST}"
  echo -e "${C2}  Local Public    ${WHT}${LOCAL_PUB}${RST}"
  echo -e "${C3}  Peer Public     ${WHT}${REMOTE_PUB}${RST}"
  echo -e "${C5}  Local Tunnel    ${WHT}${TUN_LOCAL}/30${RST}"
  echo -e "${C6}  Peer Tunnel     ${WHT}${TUN_REMOTE}/30${RST}"
  echo -e "${C7}  MTU             ${WHT}${MTU}${RST}"
  echo -e "${C10}  NAT Mode        ${WHT}$([[ $NAT_MODE == 1 ]] && echo yes || echo no)${RST}"
  echo -e "${C11}  PSK             ${WHT}${PSK}${RST}"
  line

  ask_choice "Proceed with these settings? y/n" "y" go "y" "n" "Y" "N"
  [[ "${go,,}" == "y" ]]
}

# ---------- writers ----------
write_conf() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# generated by GRE over IPsec Tunnel Manager v$VERSION
IF_NAME="$IF_NAME"
ROLE="$ROLE"
LOCAL_PUB="$LOCAL_PUB"
REMOTE_PUB="$REMOTE_PUB"
TUN_LOCAL="$TUN_LOCAL"
TUN_REMOTE="$TUN_REMOTE"
MTU="$MTU"
PSK="$PSK"
NAT_MODE="$NAT_MODE"
PRIV_IP="$PRIV_IP"
BACKEND="$BACKEND"
SWAN_SVC="$SWAN_SVC"
EOF
  chmod 600 "$CONF_FILE"

  cat > "$UP_SH" <<'UPEOF'
#!/usr/bin/env bash
set -u
source /etc/gre-ipsec/tunnel.conf
modprobe ip_gre 2>/dev/null || true
if ip link show "$IF_NAME" >/dev/null 2>&1; then
  ip link del "$IF_NAME" 2>/dev/null || true
fi
GRE_LOCAL="$LOCAL_PUB"
if [[ "$NAT_MODE" == "1" && -n "$PRIV_IP" ]]; then
  GRE_LOCAL="$PRIV_IP"
fi
ip tunnel add "$IF_NAME" mode gre local "$GRE_LOCAL" remote "$REMOTE_PUB" ttl 255
ip link set "$IF_NAME" mtu "$MTU" up
ip addr add "${TUN_LOCAL}/30" dev "$IF_NAME"
exit 0
UPEOF

  cat > "$DOWN_SH" <<'DOWNEOF'
#!/usr/bin/env bash
set -u
source /etc/gre-ipsec/tunnel.conf
ip link del "$IF_NAME" 2>/dev/null || true
exit 0
DOWNEOF
  chmod +x "$UP_SH" "$DOWN_SH"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GRE over IPsec Tunnel ($IF_NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$UP_SH
ExecStop=$DOWN_SH

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_ipsec_starter() {
  mkdir -p /etc/ipsec.d
  local encap="no"
  [[ "$NAT_MODE" == "1" ]] && encap="yes"
  cat > "$IPSEC_CONF" <<EOF
conn $CONN_NAME
    keyexchange=ikev2
    type=transport
    authby=secret
    left=%any
    leftid=$LOCAL_PUB
    leftprotoport=gre
    right=$REMOTE_PUB
    rightid=$REMOTE_PUB
    rightprotoport=gre
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048!
    esp=aes256-sha256,aes128-sha256!
    forceencaps=$encap
    dpdaction=restart
    dpddelay=30s
    closeaction=restart
    keyingtries=%forever
    auto=start
EOF
  chmod 600 "$IPSEC_CONF"

  cat > "$IPSEC_SECRETS" <<EOF
$LOCAL_PUB $REMOTE_PUB : PSK "$PSK"
EOF
  chmod 600 "$IPSEC_SECRETS"

  touch /etc/ipsec.conf /etc/ipsec.secrets
  grep -qF "include $IPSEC_CONF" /etc/ipsec.conf || echo "include $IPSEC_CONF" >> /etc/ipsec.conf
  grep -qF "include $IPSEC_SECRETS" /etc/ipsec.secrets || echo "include $IPSEC_SECRETS" >> /etc/ipsec.secrets
}

write_ipsec_swanctl() {
  mkdir -p /etc/swanctl/conf.d
  local encap="no"
  [[ "$NAT_MODE" == "1" ]] && encap="yes"
  cat > "$SWANCTL_CONF" <<EOF
connections {
    $CONN_NAME {
        version = 2
        local_addrs  = %any
        remote_addrs = $REMOTE_PUB
        proposals = aes256-sha256-modp2048,aes128-sha256-modp2048
        encap = $encap
        dpd_delay = 30s
        local {
            auth = psk
            id = $LOCAL_PUB
        }
        remote {
            auth = psk
            id = $REMOTE_PUB
        }
        children {
            gre {
                local_ts  = $LOCAL_PUB[gre]
                remote_ts = $REMOTE_PUB[gre]
                mode = transport
                esp_proposals = aes256-sha256,aes128-sha256
                start_action = start
                dpd_action = restart
                close_action = restart
            }
        }
    }
}

secrets {
    ike-$CONN_NAME {
        id-1 = $LOCAL_PUB
        id-2 = $REMOTE_PUB
        secret = "$PSK"
    }
}
EOF
  chmod 600 "$SWANCTL_CONF"
}

write_charon_tuning() {
  if [[ -d /etc/strongswan.d ]]; then
    cat > /etc/strongswan.d/gre-ipsec.conf <<'CHEOF'
charon {
    retransmit_tries = 3
    retransmit_timeout = 3.0
    retransmit_base = 1.4
    install_routes = no
}
CHEOF
  fi
}

apply_sysctl() {
  local f=/etc/sysctl.d/99-gre-ipsec.conf
  cat > "$f" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
  sysctl -p "$f" >/dev/null 2>&1
  sysctl -w "net.ipv4.conf.${IF_NAME}.rp_filter=0" >/dev/null 2>&1
}

open_firewall() {
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null  || iptables -I INPUT -p udp --dport 500 -j ACCEPT
    iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 4500 -j ACCEPT
    iptables -C INPUT -p esp -j ACCEPT 2>/dev/null || iptables -I INPUT -p esp -j ACCEPT
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -I INPUT -p gre -j ACCEPT
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 500/udp  >/dev/null 2>&1
    ufw allow 4500/udp >/dev/null 2>&1
    ufw allow proto gre from any >/dev/null 2>&1
  fi
}

restart_swan() {
  if [[ -n "$SWAN_SVC" ]]; then
    timeout 30 systemctl enable "$SWAN_SVC" >/dev/null 2>&1
    timeout 40 systemctl restart "$SWAN_SVC" >/dev/null 2>&1
  else
    timeout 40 ipsec restart >/dev/null 2>&1
  fi
  sleep 3
  if [[ "$BACKEND" == "swanctl" ]]; then
    timeout 20 swanctl --load-all >/dev/null 2>&1
  fi
}

bring_up_sa() {
  if [[ "$BACKEND" == "swanctl" ]]; then
    timeout 25 swanctl --initiate --child gre >/dev/null 2>&1
  else
    timeout 25 ipsec up "$CONN_NAME" >/dev/null 2>&1
  fi
}

wait_for_sa() {
  local tries="${1:-8}" i
  for ((i = 1; i <= tries; i++)); do
    sa_established && return 0
    sleep 2
  done
  return 1
}

# ---------- success screen ----------
success_screen() {
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  local local_label peer_label fb_local fb_peer
  if [[ "$ROLE" == "iran" ]]; then fb_local="IRAN"; fb_peer="KHAREJ"; else fb_local="KHAREJ"; fb_peer="IRAN"; fi

  step "Resolving endpoint locations"
  local_label="$(label_for_ip "$LOCAL_PUB" "$fb_local")"
  peer_label="$(label_for_ip "$REMOTE_PUB" "$fb_peer")"
  if [[ "$local_label" == "$peer_label" ]]; then
    local_label="$fb_local"; peer_label="$fb_peer"
  fi

  header
  echo
  green_box_line ""
  green_box_line "        TUNNEL CREATED SUCCESSFULLY"
  green_box_line ""
  green_box_line "$(printf '%-8s %-16s ->  %s' "$local_label" "$LOCAL_PUB" "$TUN_LOCAL")"
  green_box_line "$(printf '%-8s %-16s ->  %s' "$peer_label" "$REMOTE_PUB" "$TUN_REMOTE")"
  green_box_line ""
  green_box_line "  Interface: $IF_NAME    MTU: $MTU    Encrypted: yes"
  green_box_line ""
  echo
}

# ---------- diagnostics ----------
run_diagnostics() {
  header
  status_banner
  detect_backend
  echo -e "${C1}Diagnostics${RST}"
  line

  local virt
  virt="$(systemd-detect-virt -c 2>/dev/null || echo none)"
  echo -e "${C2}Virtualization      ${WHT}${virt}${RST}"
  echo -e "${C3}GRE module          ${WHT}$([[ -d /sys/module/ip_gre ]] && echo loaded || echo "NOT loaded")${RST}"
  echo -e "${C4}IPsec backend       ${WHT}${BACKEND:-none}${RST}"
  echo -e "${C5}strongSwan service  ${WHT}${SWAN_SVC:-none} ($(systemctl is-active "${SWAN_SVC:-nonexistent}" 2>/dev/null))${RST}"
  echo -e "${C6}GRE interface       ${WHT}$(ip -4 -o addr show dev "$IF_NAME" 2>/dev/null | awk '{print $4}' || echo missing)${RST}"
  line

  if is_installed; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    echo -e "${C7}IKE / ESP state${RST}"
    if [[ "$BACKEND" == "swanctl" ]]; then
      timeout 10 swanctl --list-sas 2>/dev/null | head -20
    else
      timeout 10 ipsec status 2>/dev/null | head -20
    fi
    line
    echo -e "${C8}Recent strongSwan log${RST}"
    [[ -n "$SWAN_SVC" ]] && journalctl -u "$SWAN_SVC" -n 20 --no-pager 2>/dev/null | tail -20
    line
  fi

  echo -e "${C9}Common causes when the tunnel does not come up${RST}"
  echo -e "${C10}  1. Provider blocks protocol 47 (GRE) or 50 (ESP) - very common on some VPS${RST}"
  echo -e "${C11}  2. UDP 500 / 4500 filtered upstream${RST}"
  echo -e "${C1}  3. PSK does not match between the two servers${RST}"
  echo -e "${C2}  4. Peer public IP typed incorrectly on one side${RST}"
  echo -e "${C3}  5. Server is a container (LXC/OpenVZ) without kernel GRE support${RST}"
  echo -e "${C4}  6. Peer server not installed yet${RST}"
  pause
}

# ---------- install ----------
do_install() {
  header
  status_banner
  if is_installed; then
    warn "A tunnel is already configured. Continuing will overwrite it."
    local c=""
    ask_choice "Continue? y/n" "n" c "y" "n" "Y" "N"
    [[ "${c,,}" == "y" ]] || return 0
  fi

  if ! gather_inputs; then
    warn "Installation cancelled."
    pause; return 0
  fi

  echo
  if ! preflight; then
    err "This server cannot host a GRE/IPsec tunnel. Installation aborted."
    pause; return 1
  fi

  echo
  install_deps || { pause; return 1; }

  step "Writing tunnel configuration"; write_conf
  step "Creating systemd unit";        write_service
  step "Writing IPsec configuration"
  if [[ "$BACKEND" == "swanctl" ]]; then write_ipsec_swanctl; else write_ipsec_starter; fi
  write_charon_tuning
  step "Applying sysctl settings";     apply_sysctl
  step "Opening firewall (udp/500, udp/4500, esp, gre)"; open_firewall

  step "Starting GRE interface"
  timeout 20 systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  timeout 30 systemctl restart "$SERVICE_NAME" >/dev/null 2>&1

  step "Restarting strongSwan"
  restart_swan

  step "Negotiating IPsec SA"
  bring_up_sa
  wait_for_sa 8

  # shellcheck disable=SC1090
  source "$CONF_FILE"

  local gre_ok=0 sa_ok=0 ping_ok=0
  iface_up && gre_ok=1
  sa_established && sa_ok=1
  ((gre_ok == 1)) && ping_peer 3 && ping_ok=1

  if ((gre_ok == 1 && sa_ok == 1 && ping_ok == 1)); then
    success_screen
    pause
    return 0
  fi

  echo
  ((gre_ok == 1)) && ok "GRE interface $IF_NAME is up." || err "GRE interface was not created."
  ((sa_ok == 1))  && ok "IPsec SA established." || err "IPsec SA not established."
  ((ping_ok == 1)) && ok "Peer $TUN_REMOTE is reachable." || err "Peer $TUN_REMOTE is not reachable."
  echo
  warn "Tunnel is not fully up yet."
  warn "If the peer server is not configured, install there and run Auto Test."
  warn "Otherwise use menu option 6 (Diagnostics) to find the cause."
  pause
  return 1
}

# ---------- auto test ----------
auto_test() {
  header
  status_banner
  if ! is_installed; then
    err "No tunnel configured on this server."
    pause; return
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  detect_backend

  echo -e "${C1}Running automatic tunnel test${RST}"
  line

  local gre_ok=0 sa_ok=0 ping_ok=0 loss="100" rtt="n/a"

  step "Checking GRE interface"
  if iface_up; then gre_ok=1; ok "Interface $IF_NAME is up ($TUN_LOCAL)."; else err "Interface $IF_NAME is down."; fi

  step "Checking IPsec security association"
  if sa_established; then
    sa_ok=1; ok "IPsec SA is ESTABLISHED."
  else
    err "IPsec SA is not established."
    step "Attempting to bring the SA up"
    bring_up_sa
    wait_for_sa 5 && { sa_ok=1; ok "IPsec SA is now ESTABLISHED."; } || err "SA still not established."
  fi

  step "Pinging peer tunnel IP ($TUN_REMOTE)"
  local out=""
  if ((gre_ok == 1)); then
    out="$(timeout 15 ping -c 5 -W 2 -I "$IF_NAME" "$TUN_REMOTE" 2>/dev/null)"
    loss="$(echo "$out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')"
    loss="${loss:-100}"
    rtt="$(echo "$out" | awk -F'/' '/rtt|round-trip/ {print $5" ms"}')"
    rtt="${rtt:-n/a}"
    if ((loss < 100)); then ping_ok=1; ok "Peer replied. Packet loss: ${loss}%  avg RTT: ${rtt}"; else err "No reply from $TUN_REMOTE."; fi
  fi

  echo
  if ((gre_ok == 1 && sa_ok == 1 && ping_ok == 1)); then
    success_screen
    put_center "All tests passed - tunnel is UP and encrypted." "$FG_OK"
    echo
  else
    line
    err "Tunnel test FAILED."
    ((gre_ok == 0))  && echo -e "${FG_ERR}  - GRE interface is not up${RST}"
    ((sa_ok == 0))   && echo -e "${FG_ERR}  - IPsec SA is not established${RST}"
    ((ping_ok == 0)) && echo -e "${FG_ERR}  - Peer tunnel IP is not reachable${RST}"
    echo
    warn "Run menu option 6 (Diagnostics) for details."
  fi
  pause
}

# ---------- info ----------
show_info() {
  header
  status_banner
  if ! is_installed; then
    err "No tunnel configured on this server."
    pause; return
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  detect_backend

  local fb_local fb_peer local_label peer_label
  if [[ "$ROLE" == "iran" ]]; then fb_local="IRAN"; fb_peer="KHAREJ"; else fb_local="KHAREJ"; fb_peer="IRAN"; fi
  local_label="$(label_for_ip "$LOCAL_PUB" "$fb_local")"
  peer_label="$(label_for_ip "$REMOTE_PUB" "$fb_peer")"
  [[ "$local_label" == "$peer_label" ]] && { local_label="$fb_local"; peer_label="$fb_peer"; }

  echo -e "${C1}Endpoints${RST}"
  echo -e "${C2}  $(printf '%-8s %-16s -> local %s' "$local_label" "$LOCAL_PUB" "$TUN_LOCAL")${RST}"
  echo -e "${C3}  $(printf '%-8s %-16s -> local %s' "$peer_label" "$REMOTE_PUB" "$TUN_REMOTE")${RST}"
  line
  echo -e "${C5}Interface           ${WHT}${IF_NAME}${RST}"
  echo -e "${C6}MTU                 ${WHT}${MTU}${RST}"
  echo -e "${C7}NAT Mode            ${WHT}$([[ $NAT_MODE == 1 ]] && echo yes || echo no)${RST}"
  echo -e "${C8}Backend             ${WHT}${BACKEND}${RST}"
  line

  local live
  live="$(ip -4 -o addr show dev "$IF_NAME" 2>/dev/null | awk '{print $4}')"
  [[ -n "$live" ]] && ok "Interface is up with address $live" || err "Interface $IF_NAME is down or missing."
  sa_established && ok "IPsec tunnel is ESTABLISHED." || warn "IPsec tunnel is not established."
  pause
}

peer_setup() {
  header
  status_banner
  if ! is_installed; then
    err "Configure this server first."
    pause; return
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  local peer_role
  [[ "$ROLE" == "iran" ]] && peer_role="KHAREJ" || peer_role="IRAN"

  echo -e "${C1}Use these values when running this script on the PEER server:${RST}"
  line
  echo -e "${C2}  Role                 ${WHT}${peer_role}${RST}"
  echo -e "${C3}  This Server Public   ${WHT}${REMOTE_PUB}${RST}"
  echo -e "${C4}  Peer Server Public   ${WHT}${LOCAL_PUB}${RST}"
  echo -e "${C5}  This Side Tunnel IP  ${WHT}${TUN_REMOTE}${RST}"
  echo -e "${C6}  Peer Side Tunnel IP  ${WHT}${TUN_LOCAL}${RST}"
  echo -e "${C7}  MTU                  ${WHT}${MTU}${RST}"
  echo -e "${C8}  Shared Secret (PSK)  ${WHT}${PSK}${RST}"
  line
  warn "The PSK must be entered exactly the same on the peer server."
  pause
}

# ---------- management ----------
manage_menu() {
  local choice=""
  while true; do
    header
    status_banner
    detect_backend
    echo -e "${C1}  1) Start${RST}"
    echo -e "${C2}  2) Stop${RST}"
    echo -e "${C3}  3) Restart${RST}"
    echo -e "${C5}  4) Service Status${RST}"
    echo -e "${C6}  5) IPsec Status${RST}"
    echo -e "${C7}  6) Bring IPsec Up${RST}"
    echo -e "${C8}  7) Logs${RST}"
    echo -e "${GRY}  0) Back${RST}"
    echo
    read -rp "$(echo -e "${C9}Select${RST} ${GRY}(${WHT}0${GRY})${RST}: ")" choice
    choice="${choice:-0}"
    case "$choice" in
      1) timeout 30 systemctl start "$SERVICE_NAME"; bring_up_sa; ok "Started."; pause ;;
      2) if [[ "$BACKEND" == "swanctl" ]]; then timeout 15 swanctl --terminate --child gre >/dev/null 2>&1
         else timeout 15 ipsec down "$CONN_NAME" >/dev/null 2>&1; fi
         timeout 30 systemctl stop "$SERVICE_NAME"; ok "Stopped."; pause ;;
      3) timeout 30 systemctl restart "$SERVICE_NAME"; restart_swan; bring_up_sa; ok "Restarted."; pause ;;
      4) systemctl status "$SERVICE_NAME" --no-pager; pause ;;
      5) if [[ "$BACKEND" == "swanctl" ]]; then timeout 10 swanctl --list-sas 2>/dev/null | head -40
         else timeout 10 ipsec statusall 2>/dev/null | head -40; fi; pause ;;
      6) bring_up_sa; sa_established && ok "SA established." || err "SA not established."; pause ;;
      7) journalctl -u "$SERVICE_NAME" -n 30 --no-pager
         echo; [[ -n "$SWAN_SVC" ]] && journalctl -u "$SWAN_SVC" -n 30 --no-pager 2>/dev/null; pause ;;
      0) return ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

do_uninstall() {
  header
  status_banner
  local c=""
  ask_choice "Remove tunnel and all its configuration? y/n" "n" c "y" "n" "Y" "N"
  [[ "${c,,}" == "y" ]] || return
  detect_backend

  if [[ "$BACKEND" == "swanctl" ]]; then timeout 15 swanctl --terminate --child gre >/dev/null 2>&1
  else timeout 15 ipsec down "$CONN_NAME" >/dev/null 2>&1; fi
  timeout 30 systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
  [[ -x "$DOWN_SH" ]] && "$DOWN_SH" >/dev/null 2>&1
  rm -f "$SERVICE_FILE" "$IPSEC_CONF" "$IPSEC_SECRETS" "$SWANCTL_CONF" \
        /etc/strongswan.d/gre-ipsec.conf /etc/sysctl.d/99-gre-ipsec.conf
  sed -i "\|include $IPSEC_CONF|d" /etc/ipsec.conf 2>/dev/null
  sed -i "\|include $IPSEC_SECRETS|d" /etc/ipsec.secrets 2>/dev/null
  rm -rf "$CONF_DIR"
  systemctl daemon-reload
  [[ -n "$SWAN_SVC" ]] && timeout 30 systemctl restart "$SWAN_SVC" >/dev/null 2>&1
  ok "Tunnel removed."
  pause
}

main_menu() {
  local choice=""
  while true; do
    header
    status_banner
    echo -e "${C1}  1) Install Tunnel${RST}"
    echo -e "${C5}  2) Tunnel Management${RST}"
    echo -e "${C6}  3) Show Tunnel Info${RST}"
    echo -e "${C2}  4) Auto Test${RST}"
    echo -e "${C8}  5) Peer Server Values${RST}"
    echo -e "${C10}  6) Diagnostics${RST}"
    echo -e "${C4}  7) Uninstall${RST}"
    echo -e "${GRY}  0) Exit${RST}"
    echo
    read -rp "$(echo -e "${C9}Select${RST} ${GRY}(${WHT}1${GRY})${RST}: ")" choice
    choice="${choice:-1}"
    case "$choice" in
      1) do_install ;;
      2) manage_menu ;;
      3) show_info ;;
      4) auto_test ;;
      5) peer_setup ;;
      6) run_diagnostics ;;
      7) do_uninstall ;;
      0) echo; exit 0 ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

need_root
detect_backend
main_menu
