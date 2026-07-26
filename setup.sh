#!/usr/bin/env bash
# =============================================================
#  GRE over IPsec Tunnel Manager
#  Version: 1.1.0
# =============================================================
set -uo pipefail

VERSION="1.1.0"
CONF_DIR="/etc/gre-ipsec"
CONF_FILE="$CONF_DIR/tunnel.conf"
UP_SH="$CONF_DIR/up.sh"
DOWN_SH="$CONF_DIR/down.sh"
SERVICE_NAME="gre-ipsec.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
IPSEC_CONF="/etc/ipsec.d/gre-ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.d/gre-ipsec.secrets"

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
WHT=$'\033[38;5;255m'
GRY=$'\033[38;5;245m'
RST=$'\033[0m'
# status only
BG_OK=$'\033[48;5;28;38;5;16m'
BG_ERR=$'\033[48;5;124;38;5;231m'
BG_WARN=$'\033[48;5;208;38;5;16m'
FG_OK=$'\033[38;5;40m'
FG_ERR=$'\033[38;5;196m'
FG_WARN=$'\033[38;5;214m'

# ---------- globals (initialized for set -u) ----------
ROLE=""
LOCAL_PUB=""
REMOTE_PUB=""
TUN_LOCAL=""
TUN_REMOTE=""
PSK=""
MTU=""
IF_NAME="gre1"
SWAN_SVC=""

step() { echo -e "${GRY}>>${RST} ${C9}$1${RST}"; }
ok()   { echo -e "${BG_OK} OK ${RST} ${FG_OK}$1${RST}"; }
err()  { echo -e "${BG_ERR} ERROR ${RST} ${FG_ERR}$1${RST}"; }
warn() { echo -e "${BG_WARN} WARN ${RST} ${FG_WARN}$1${RST}"; }
line() { echo -e "${GRY}--------------------------------------------------------------${RST}"; }
pause(){ echo; read -rp "$(echo -e "${GRY}Press Enter to continue...${RST}")" _; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi
}

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
    echo -e "${BG_OK} INSTALLED ${RST}  ${GRY}interface:${RST} ${WHT}${IF_NAME}${RST}  ${GRY}service:${RST} ${WHT}${st}${RST}"
  else
    echo -e "${BG_ERR} NOT INSTALLED ${RST}  ${GRY}no tunnel configured on this server${RST}"
  fi
  line
}

# ---------- validation helpers (never abort, always re-ask) ----------
valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra o <<< "$ip"
  for x in "${o[@]}"; do
    ((x >= 0 && x <= 255)) || return 1
  done
  return 0
}

ask_ip() {
  # $1 prompt, $2 default (may be empty), $3 global var name
  local prompt="$1" def="$2" varname="$3" input=""
  while true; do
    if [[ -n "$def" ]]; then
      read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
      input="${input:-$def}"
    else
      read -rp "$(echo -e "${C7}${prompt}${RST}: ")" input
    fi
    if valid_ip "$input"; then
      printf -v "$varname" '%s' "$input"
      return 0
    fi
    err "Invalid IPv4 address. Please try again."
  done
}

ask_num() {
  local prompt="$1" def="$2" min="$3" max="$4" varname="$5" input=""
  while true; do
    read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
    input="${input:-$def}"
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= min && input <= max)); then
      printf -v "$varname" '%s' "$input"
      return 0
    fi
    err "Enter a number between $min and $max."
  done
}

ask_choice() {
  local prompt="$1" def="$2" varname="$3" input=""
  shift 3
  local opts=("$@")
  while true; do
    read -rp "$(echo -e "${C7}${prompt}${RST} ${GRY}(${WHT}${def}${GRY})${RST}: ")" input
    input="${input:-$def}"
    for o in "${opts[@]}"; do
      if [[ "$input" == "$o" ]]; then
        printf -v "$varname" '%s' "$input"
        return 0
      fi
    done
    err "Invalid choice. Allowed: ${opts[*]}"
  done
}

check_ipsec_ports() {
  local busy=""
  if command -v ss >/dev/null 2>&1; then
    ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE '(:500)$'  && busy="500"
    ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE '(:4500)$' && busy="${busy:+$busy, }4500"
  fi
  if [[ -n "$busy" ]]; then
    warn "UDP port(s) $busy already in use. If it is not strongSwan, IPsec will fail."
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  [[ -z "$ip" ]] && ip="$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null)"
  echo "$ip"
}

detect_swan_svc() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^strongswan-starter\.service'; then
    SWAN_SVC="strongswan-starter"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^strongswan\.service'; then
    SWAN_SVC="strongswan"
  else
    SWAN_SVC=""
  fi
}

# ---------- dependencies ----------
install_deps() {
  echo -e "${C1}Installing dependencies...${RST}"
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq iproute2 iptables curl strongswan strongswan-starter \
      libstrongswan-standard-plugins >/dev/null 2>&1 || \
    apt-get install -y -qq iproute2 iptables curl strongswan >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q iproute iptables curl strongswan >/dev/null 2>&1
  else
    warn "Unsupported package manager. Install strongSwan manually."
  fi

  if ! command -v ipsec >/dev/null 2>&1; then
    err "strongSwan 'ipsec' command not found. Install it manually and re-run."
    return 1
  fi
  ok "Dependencies ready."
  return 0
}

# ---------- input gathering ----------
gather_inputs() {
  local detected role_in=""
  detected="$(detect_public_ip)"

  echo -e "${C1}Server Role${RST}"
  echo -e "${C2}  1) Side A  ${GRY}- tunnel IP 10.10.10.1${RST}"
  echo -e "${C3}  2) Side B  ${GRY}- tunnel IP 10.10.10.2${RST}"
  ask_choice "Select role" "1" role_in "1" "2"
  ROLE="$role_in"

  local def_local def_remote
  if [[ "$ROLE" == "1" ]]; then
    def_local="10.10.10.1"; def_remote="10.10.10.2"
  else
    def_local="10.10.10.2"; def_remote="10.10.10.1"
  fi

  echo
  echo -e "${C4}Public Endpoints${RST}"
  ask_ip "This Server Public IP" "$detected" LOCAL_PUB

  while true; do
    ask_ip "Peer Server Public IP" "" REMOTE_PUB
    if [[ "$REMOTE_PUB" == "$LOCAL_PUB" ]]; then
      err "Peer IP cannot be the same as this server IP."
      continue
    fi
    break
  done

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

  local def_psk psk_in=""
  def_psk="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)"
  while true; do
    read -rp "$(echo -e "${C8}Shared Secret (PSK)${RST} ${GRY}(${WHT}${def_psk}${GRY})${RST}: ")" psk_in
    psk_in="${psk_in:-$def_psk}"
    if ((${#psk_in} >= 8)); then
      PSK="$psk_in"; break
    fi
    err "PSK must be at least 8 characters."
  done

  echo
  check_ipsec_ports

  echo
  line
  echo -e "${C9}Review${RST}"
  echo -e "${C1}  Role            ${WHT}Side $( [[ $ROLE == 1 ]] && echo A || echo B )${RST}"
  echo -e "${C2}  Local Public    ${WHT}${LOCAL_PUB}${RST}"
  echo -e "${C3}  Peer Public     ${WHT}${REMOTE_PUB}${RST}"
  echo -e "${C5}  Local Tunnel    ${WHT}${TUN_LOCAL}/30${RST}"
  echo -e "${C6}  Peer Tunnel     ${WHT}${TUN_REMOTE}/30${RST}"
  echo -e "${C7}  MTU             ${WHT}${MTU}${RST}"
  echo -e "${C10} PSK             ${WHT}${PSK}${RST}"
  line

  local go=""
  ask_choice "Proceed with these settings? y/n" "y" go "y" "n" "Y" "N"
  [[ "${go,,}" == "y" ]]
}

# ---------- writers ----------
write_conf() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
# GRE over IPsec tunnel configuration - generated by manager v$VERSION
IF_NAME="$IF_NAME"
ROLE="$ROLE"
LOCAL_PUB="$LOCAL_PUB"
REMOTE_PUB="$REMOTE_PUB"
TUN_LOCAL="$TUN_LOCAL"
TUN_REMOTE="$TUN_REMOTE"
MTU="$MTU"
PSK="$PSK"
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
ip tunnel add "$IF_NAME" mode gre local "$LOCAL_PUB" remote "$REMOTE_PUB" ttl 255
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
After=network-online.target strongswan-starter.service
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

write_ipsec() {
  mkdir -p /etc/ipsec.d
  cat > "$IPSEC_CONF" <<EOF
conn gre-ipsec
    keyexchange=ikev2
    type=transport
    authby=secret
    left=$LOCAL_PUB
    leftprotoport=gre
    right=$REMOTE_PUB
    rightprotoport=gre
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    dpdaction=restart
    dpddelay=30s
    closeaction=restart
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

  # keep IKE retries short so the CLI never blocks for minutes on a dead peer
  if [[ -d /etc/strongswan.d ]]; then
    cat > /etc/strongswan.d/gre-ipsec.conf <<'CHEOF'
charon {
    retransmit_tries = 3
    retransmit_timeout = 3.0
    retransmit_base = 1.4
}
CHEOF
  fi
}

apply_sysctl() {
  local f=/etc/sysctl.d/99-gre-ipsec.conf
  cat > "$f" <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
  sysctl -p "$f" >/dev/null 2>&1
}

open_firewall() {
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 500 -j ACCEPT
    iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 4500 -j ACCEPT
    iptables -C INPUT -p esp -j ACCEPT 2>/dev/null || iptables -I INPUT -p esp -j ACCEPT
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -I INPUT -p gre -j ACCEPT
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 500/udp  >/dev/null 2>&1
    ufw allow 4500/udp >/dev/null 2>&1
  fi
}

# ---------- actions ----------
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

  install_deps || { pause; return 1; }

  step "Writing tunnel configuration"
  write_conf

  step "Creating systemd unit"
  write_service

  step "Writing IPsec configuration"
  write_ipsec

  step "Applying sysctl settings"
  apply_sysctl

  step "Opening firewall (udp/500, udp/4500, esp, gre)"
  open_firewall

  step "Enabling and starting GRE interface"
  timeout 20 systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  timeout 30 systemctl restart "$SERVICE_NAME" >/dev/null 2>&1

  detect_swan_svc
  if [[ -n "$SWAN_SVC" ]]; then
    step "Restarting strongSwan ($SWAN_SVC)"
    timeout 20 systemctl enable "$SWAN_SVC" >/dev/null 2>&1
    timeout 30 systemctl restart "$SWAN_SVC" >/dev/null 2>&1
  else
    step "Restarting strongSwan (legacy starter)"
    timeout 30 ipsec restart >/dev/null 2>&1
  fi
  sleep 3

  step "Negotiating IPsec SA (max 20s, non-blocking)"
  timeout 20 ipsec up gre-ipsec >/dev/null 2>&1

  echo
  if ip link show "$IF_NAME" >/dev/null 2>&1; then
    ok "GRE interface $IF_NAME created."
  else
    err "GRE interface was not created. Check: journalctl -u $SERVICE_NAME"
  fi

  if timeout 10 ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
    ok "IPsec SA established with $REMOTE_PUB."
  else
    warn "IPsec not established yet. This is normal until the peer is configured."
    warn "After configuring the peer, run: ipsec up gre-ipsec"
  fi

  echo
  show_info_body
  pause
}

show_info_body() {
  if ! is_installed; then
    err "No tunnel configured on this server."
    return
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"

  line
  echo -e "${C1}Local Tunnel IP      ${WHT}${TUN_LOCAL}${RST}"
  echo -e "${C2}Peer Tunnel IP       ${WHT}${TUN_REMOTE}${RST}"
  echo -e "${C3}Interface            ${WHT}${IF_NAME}${RST}"
  echo -e "${C4}MTU                  ${WHT}${MTU}${RST}"
  echo -e "${C5}Local Public IP      ${WHT}${LOCAL_PUB}${RST}"
  echo -e "${C6}Peer Public IP       ${WHT}${REMOTE_PUB}${RST}"
  line

  local live
  live="$(ip -4 -o addr show dev "$IF_NAME" 2>/dev/null | awk '{print $4}')"
  if [[ -n "$live" ]]; then
    ok "Interface is up with address $live"
  else
    err "Interface $IF_NAME is down or missing."
  fi

  if timeout 10 ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
    ok "IPsec tunnel is ESTABLISHED."
  else
    warn "IPsec tunnel is not established."
  fi

  echo -e "${GRY}Testing reachability to peer tunnel IP...${RST}"
  if timeout 8 ping -c 2 -W 2 -I "$IF_NAME" "$TUN_REMOTE" >/dev/null 2>&1; then
    ok "Peer $TUN_REMOTE is reachable over the tunnel."
  else
    warn "Peer $TUN_REMOTE did not reply (peer may not be configured yet)."
  fi
}

show_info() {
  header
  status_banner
  show_info_body
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
  echo -e "${C1}Use these values when running this script on the PEER server:${RST}"
  line
  echo -e "${C2}  Role                 ${WHT}Side $( [[ $ROLE == 1 ]] && echo B || echo A )${RST}"
  echo -e "${C3}  This Server Public   ${WHT}${REMOTE_PUB}${RST}"
  echo -e "${C4}  Peer Server Public   ${WHT}${LOCAL_PUB}${RST}"
  echo -e "${C5}  This Side Tunnel IP  ${WHT}${TUN_REMOTE}${RST}"
  echo -e "${C6}  Peer Side Tunnel IP  ${WHT}${TUN_LOCAL}${RST}"
  echo -e "${C7}  MTU                  ${WHT}${MTU}${RST}"
  echo -e "${C8}  Shared Secret (PSK)  ${WHT}${PSK}${RST}"
  line
  pause
}

manage_menu() {
  local choice=""
  while true; do
    header
    status_banner
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
      1) timeout 30 systemctl start "$SERVICE_NAME"; timeout 20 ipsec up gre-ipsec >/dev/null 2>&1; ok "Started."; pause ;;
      2) timeout 15 ipsec down gre-ipsec >/dev/null 2>&1; timeout 30 systemctl stop "$SERVICE_NAME"; ok "Stopped."; pause ;;
      3) detect_swan_svc
         timeout 30 systemctl restart "$SERVICE_NAME"
         if [[ -n "$SWAN_SVC" ]]; then timeout 30 systemctl restart "$SWAN_SVC" >/dev/null 2>&1; else timeout 30 ipsec restart >/dev/null 2>&1; fi
         sleep 2; timeout 20 ipsec up gre-ipsec >/dev/null 2>&1; ok "Restarted."; pause ;;
      4) systemctl status "$SERVICE_NAME" --no-pager; pause ;;
      5) timeout 10 ipsec statusall 2>/dev/null | head -40; pause ;;
      6) timeout 25 ipsec up gre-ipsec; pause ;;
      7) journalctl -u "$SERVICE_NAME" -n 40 --no-pager
         detect_swan_svc
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

  timeout 15 ipsec down gre-ipsec >/dev/null 2>&1
  timeout 30 systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
  [[ -x "$DOWN_SH" ]] && "$DOWN_SH" >/dev/null 2>&1
  rm -f "$SERVICE_FILE" "$IPSEC_CONF" "$IPSEC_SECRETS" /etc/strongswan.d/gre-ipsec.conf
  sed -i "\|include $IPSEC_CONF|d" /etc/ipsec.conf 2>/dev/null
  sed -i "\|include $IPSEC_SECRETS|d" /etc/ipsec.secrets 2>/dev/null
  rm -rf "$CONF_DIR"
  rm -f /etc/sysctl.d/99-gre-ipsec.conf
  systemctl daemon-reload
  detect_swan_svc
  if [[ -n "$SWAN_SVC" ]]; then timeout 30 systemctl restart "$SWAN_SVC" >/dev/null 2>&1; else timeout 30 ipsec restart >/dev/null 2>&1; fi
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
    echo -e "${C8}  4) Peer Server Values${RST}"
    echo -e "${C4}  5) Uninstall${RST}"
    echo -e "${GRY}  0) Exit${RST}"
    echo
    read -rp "$(echo -e "${C9}Select${RST} ${GRY}(${WHT}1${GRY})${RST}: ")" choice
    choice="${choice:-1}"
    case "$choice" in
      1) do_install ;;
      2) manage_menu ;;
      3) show_info ;;
      4) peer_setup ;;
      5) do_uninstall ;;
      0) echo; exit 0 ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

need_root
main_menu
