#!/bin/bash
# ================================================================= #
#  WIREGUARD PRO INSTALLER - v2 (hardened)                          #
#  Soporte: Ubuntu 24.04/22.04, Debian 13/12                        #
#  Mejoras: checksums, DNS pre-check, idempotencia, backup iptables,#
#           FORWARD DROP, non-interactive flags, uninstall.         #
# ================================================================= #

set -eEuo pipefail

LOG_FILE="/root/wg-installer.log"
STATE_DIR="/var/lib/wg-installer"
BACKUP_DIR="$STATE_DIR/backups"

CADDY_VERSION="2.11.2"
WGUI_VERSION="0.6.2"

declare -A CADDY_SHA256=(
  [amd64]="94391dfefe1f278ac8f387ab86162f0e88d87ff97df367f360e51e3cda3df56f"
  [arm64]="b9d88bec4254d0a98bd415ad60f97f37e4222dec96235c00b442437f5e303a32"
)
declare -A WGUI_SHA256=(
  [amd64]="2769536c2ef4cc3630b209675167afd5f199f4cc9f9f0d22ce492592dc1dc68d"
  [arm64]="4d40cdd135381faacb8d09c8046512ecb7a37e9b8cbd58f86022d8dd093de23b"
)

DOMAIN=""
WGUI_USERNAME=""
WGUI_PASSWORD=""
EMAIL=""
NON_INTERACTIVE=0
SKIP_DNS_CHECK=0
ACTION="install"
SSH_PORT=""

usage() {
  cat <<EOF >&2
Uso:
  $0 [opciones]

Opciones:
  --domain <dominio>         Dominio que apunta a este servidor
  --user <usuario>           Usuario admin para el panel
  --password <contrasena>    Contrasena admin
  --email <correo>           Correo para Let's Encrypt
  --ssh-port <puerto>        Puerto SSH (auto-detectado si se omite)
  --skip-dns-check           Omitir verificacion DNS del dominio
  --non-interactive          Exige que todos los parametros vengan por flag
  --uninstall                Desinstalar WireGuard + UI + Caddy
  -h | --help                Muestra esta ayuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --user) WGUI_USERNAME="$2"; shift 2 ;;
    --password) WGUI_PASSWORD="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; usage; exit 2 ;;
  esac
done

exec 3>&1 4>&2

UI_GREEN='\033[0;32m'
UI_BLUE='\033[0;34m'
UI_RED='\033[0;31m'
UI_YELLOW='\033[1;33m'
UI_NC='\033[0m'

ui()      { printf "%b\n" "$*" >&3; }
ui_err()  { printf "%b\n" "$*" >&4; }

BAR_W=28
STEP=0
TOTAL_STEPS=10

ui_step() {
  STEP=$((STEP+1))
  local msg="$1"
  local pct=$(( STEP * 100 / TOTAL_STEPS ))
  local filled=$(( pct * BAR_W / 100 ))
  local empty=$(( BAR_W - filled ))
  local bar
  bar="$(printf "%0.s#" $(seq 1 $filled))"
  bar="${bar}$(printf "%0.s-" $(seq 1 $empty))"
  ui "${UI_BLUE}[${STEP}/${TOTAL_STEPS}]${UI_NC} [${UI_GREEN}${bar}${UI_NC}] ${pct}%% - ${msg}"
}

banner() {
  ui "${UI_GREEN}==============================================================${UI_NC}"
  ui "${UI_GREEN}   WIREGUARD PRO INSTALLER v2 (hardened)                      ${UI_NC}"
  ui "${UI_GREEN}==============================================================${UI_NC}"
}

detect_os_ui() {
  local os_name="unknown" os_id="unknown" os_ver="unknown"
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    os_name="${PRETTY_NAME:-unknown}"
    os_id="${ID:-unknown}"
    os_ver="${VERSION_ID:-unknown}"
  fi
  ui "${UI_YELLOW}Sistema detectado:${UI_NC} ${os_name} (ID=${os_id}, VER=${os_ver})"
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then ui_err "\n${UI_RED}Error durante la operacion.${UI_NC} Revisa: ${UI_YELLOW}${LOG_FILE}${UI_NC}"; fi' ERR

[[ $EUID -ne 0 ]] && { ui_err "${UI_RED}Ejecutar como root${UI_NC}"; exit 1; }

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

do_uninstall() {
  banner
  ui "${UI_YELLOW}Desinstalando...${UI_NC}"
  exec >>"$LOG_FILE" 2>&1

  systemctl disable --now wg-quick@wg0 wireguard-ui caddy \
    wg-quick-watcher@wg0.path wg-boot-fix.service 2>/dev/null || true

  rm -f /etc/systemd/system/wireguard-ui.service \
        /etc/systemd/system/caddy.service \
        /etc/systemd/system/wg-quick-watcher@.path \
        /etc/systemd/system/wg-quick-watcher@.service \
        /etc/systemd/system/wg-boot-fix.service
  systemctl daemon-reload

  rm -f /usr/local/bin/caddy /usr/local/bin/wireguard-ui \
        /usr/local/sbin/wg-postup-inject.sh /usr/local/sbin/wg-boot-fix.sh
  rm -rf /etc/caddy /var/lib/caddy /usr/local/share/wireguard-ui
  rm -f /etc/default/wireguard-ui /etc/wireguard/wg0.conf /etc/sysctl.d/99-vpn.conf

  if [[ -f "$BACKUP_DIR/iptables.v4.backup" ]]; then
    iptables-restore < "$BACKUP_DIR/iptables.v4.backup" || true
    ui "${UI_GREEN}Restaurado iptables v4 desde backup.${UI_NC}"
  fi
  if [[ -f "$BACKUP_DIR/iptables.v6.backup" ]]; then
    ip6tables-restore < "$BACKUP_DIR/iptables.v6.backup" || true
    ui "${UI_GREEN}Restaurado iptables v6 desde backup.${UI_NC}"
  fi

  netfilter-persistent save >/dev/null 2>&1 || true
  ui "${UI_GREEN}Desinstalacion completada.${UI_NC}"
  exit 0
}

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
fi

banner
detect_os_ui
ui "=============================================="

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

if [[ $NON_INTERACTIVE -eq 1 ]]; then
  for v in DOMAIN WGUI_USERNAME WGUI_PASSWORD EMAIL; do
    if [[ -z "${!v}" ]]; then
      ui_err "${UI_RED}Falta --${v,,} en modo no interactivo.${UI_NC}"; exit 2
    fi
  done
else
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "Dominio (ej: vpn.ejemplo.com): " DOMAIN
  fi
  if [[ -z "$WGUI_USERNAME" ]]; then
    read -r -p "Usuario Admin: " WGUI_USERNAME
  fi
  if [[ -z "$WGUI_PASSWORD" ]]; then
    while :; do
      read -r -s -p "Contrasena Admin: " WGUI_PASSWORD; echo >&3
      read -r -s -p "Contrasena Admin (de nuevo): " WGUI_PASSWORD_CONFIRM; echo >&3
      [[ -z "$WGUI_PASSWORD" ]] && { ui "${UI_RED}No puede estar vacia.${UI_NC}"; continue; }
      [[ "$WGUI_PASSWORD" != "$WGUI_PASSWORD_CONFIRM" ]] && { ui "${UI_RED}No coinciden.${UI_NC}"; continue; }
      break
    done
    unset WGUI_PASSWORD_CONFIRM
  fi
  if [[ -z "$EMAIL" ]]; then
    read -r -p "Correo para Let's Encrypt: " EMAIL
  fi
fi

validate_domain "$DOMAIN" || { ui_err "${UI_RED}Dominio invalido: $DOMAIN${UI_NC}"; exit 2; }
validate_email "$EMAIL"   || { ui_err "${UI_RED}Email invalido: $EMAIL${UI_NC}"; exit 2; }

ui "Log: ${LOG_FILE}"
: > "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

log_info()    { echo "[INFO] $1"; }
log_success() { echo "[OK] $1"; }
log_error()   { echo "[ERROR] $1" >&2; }

detect_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VER="${VERSION_ID:-}"
  else
    OS_ID="unknown"; OS_LIKE=""; OS_VER=""
  fi
  case "$OS_ID" in
    ubuntu) OS_FAMILY="ubuntu" ;;
    debian) OS_FAMILY="debian" ;;
    *)
      if echo "$OS_LIKE" | grep -qi "ubuntu"; then OS_FAMILY="ubuntu"
      elif echo "$OS_LIKE" | grep -qi "debian"; then OS_FAMILY="debian"
      else OS_FAMILY="unknown"; fi
    ;;
  esac
}

ui_step "Instalando dependencias"
detect_os
log_info "OS: ${OS_FAMILY} (ID=${OS_ID}, VER=${OS_VER})"
[[ "$OS_FAMILY" == "unknown" ]] && { log_error "Solo Ubuntu/Debian."; exit 1; }

apt-get update -qq
PKGS=(
  curl tar ca-certificates openssl bind9-dnsutils
  iproute2 iptables iptables-persistent
  wireguard wireguard-tools libcap2-bin
)
if [[ "$OS_FAMILY" == "debian" ]] && ! systemctl is-active --quiet systemd-resolved; then
  PKGS+=(resolvconf)
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
if [[ "$OS_FAMILY" == "ubuntu" ]]; then
  systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi
log_success "Dependencias OK."

ui_step "Detectando red"
INTERFACE="$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"
[[ -z "$INTERFACE" ]] && { log_error "No se detecta interfaz por defecto"; exit 1; }
log_info "Interfaz: $INTERFACE"

PUBLIC_V4="$(curl -fs --max-time 5 https://api.ipify.org || true)"
PUBLIC_V6="$(curl -fs --max-time 5 https://api6.ipify.org || true)"

if ip -6 addr show dev "$INTERFACE" scope global 2>/dev/null | grep -q "inet6 "; then
  HAS_IPV6=1
else
  HAS_IPV6=0
fi

WG_ADDR_V4="172.30.0.1/24"
WG_ADDR_V6=""
if [[ $HAS_IPV6 -eq 1 ]]; then
  WG_ADDR_V6="fd42:42:42::1/64"
fi
WGUI_DEFAULT_CLIENT_ALLOWED_IPS="0.0.0.0/0"
[[ -n "$WG_ADDR_V6" ]] && WGUI_DEFAULT_CLIENT_ALLOWED_IPS="0.0.0.0/0,::/0"
WGUI_DNS="1.1.1.1,1.0.0.1"
[[ -n "$WG_ADDR_V6" ]] && WGUI_DNS="1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"
WGUI_ENDPOINT_PORT="51820"

ui_step "Verificando DNS del dominio"
if [[ $SKIP_DNS_CHECK -eq 0 ]]; then
  DOMAIN_V4="$(dig +short +time=3 +tries=2 "$DOMAIN" A | tail -n1 || true)"
  DOMAIN_V6="$(dig +short +time=3 +tries=2 "$DOMAIN" AAAA | tail -n1 || true)"
  if [[ -z "$DOMAIN_V4" && -z "$DOMAIN_V6" ]]; then
    log_error "El dominio $DOMAIN no resuelve a ninguna IP."
    ui_err "${UI_RED}DNS no resuelve: $DOMAIN. Usa --skip-dns-check si estas seguro.${UI_NC}"
    exit 1
  fi
  OK=0
  if [[ -n "$DOMAIN_V4" && -n "$PUBLIC_V4" && "$DOMAIN_V4" == "$PUBLIC_V4" ]]; then OK=1; fi
  if [[ -n "$DOMAIN_V6" && -n "$PUBLIC_V6" && "$DOMAIN_V6" == "$PUBLIC_V6" ]]; then OK=1; fi
  if [[ $OK -eq 0 ]]; then
    log_error "DNS no apunta a este servidor. Dominio=$DOMAIN_V4/$DOMAIN_V6 vs servidor=$PUBLIC_V4/$PUBLIC_V6"
    ui_err "${UI_RED}$DOMAIN apunta a $DOMAIN_V4 $DOMAIN_V6 pero este server es $PUBLIC_V4 $PUBLIC_V6.${UI_NC}"
    ui_err "${UI_YELLOW}Usa --skip-dns-check si es intencional.${UI_NC}"
    exit 1
  fi
  log_success "DNS OK"
else
  log_info "DNS pre-check omitido"
fi

if [[ -z "$SSH_PORT" ]]; then
  SSH_PORT="$(ss -tlnpH 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')"
  SSH_PORT="${SSH_PORT:-22}"
fi
log_info "SSH port: $SSH_PORT"

ui_step "Creando estructura"
mkdir -p /etc/caddy \
         /var/lib/caddy/.local/share/caddy \
         /usr/local/share/wireguard-ui/db \
         /etc/wireguard \
         /etc/iptables

if ! id "caddy" &>/dev/null; then
  useradd --system --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
fi
chown -R caddy:caddy /var/lib/caddy /etc/caddy

ui_step "Instalando Caddy ${CADDY_VERSION}"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *) log_error "Arquitectura no soportada: $ARCH"; exit 1 ;;
esac

CADDY_URL="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz"
CADDY_TMP="/tmp/caddy.tar.gz"

if [[ ! -x /usr/local/bin/caddy ]] || ! /usr/local/bin/caddy version 2>/dev/null | grep -q "v${CADDY_VERSION}"; then
  curl -fsSL "$CADDY_URL" -o "$CADDY_TMP"
  ACTUAL_SHA="$(sha256sum "$CADDY_TMP" | awk '{print $1}')"
  EXPECTED_SHA="${CADDY_SHA256[$ARCH]}"
  if [[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    log_error "Checksum Caddy no coincide. Esperado: $EXPECTED_SHA Actual: $ACTUAL_SHA"
    exit 1
  fi
  tar -C /usr/local/bin -xzf "$CADDY_TMP" caddy
  chmod +x /usr/local/bin/caddy
  rm -f "$CADDY_TMP"
fi

cat >/etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
}
$DOMAIN {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        -Server
    }
    reverse_proxy localhost:5000
}
EOF

cat >/etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
Wants=network-online.target
After=network-online.target
[Service]
Type=notify
User=caddy
Group=caddy
Environment=CADDY_DATA_DIR=/var/lib/caddy/.local/share/caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

ui_step "Instalando WireGuard UI ${WGUI_VERSION}"
WGUI_URL="https://github.com/ngoduykhanh/wireguard-ui/releases/download/v${WGUI_VERSION}/wireguard-ui-v${WGUI_VERSION}-linux-${ARCH}.tar.gz"
WGUI_TMP="/tmp/wgui.tar.gz"

if [[ ! -x /usr/local/bin/wireguard-ui ]]; then
  curl -fsSL "$WGUI_URL" -o "$WGUI_TMP"
  ACTUAL_SHA="$(sha256sum "$WGUI_TMP" | awk '{print $1}')"
  EXPECTED_SHA="${WGUI_SHA256[$ARCH]}"
  if [[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    log_error "Checksum WG-UI no coincide. Esperado: $EXPECTED_SHA Actual: $ACTUAL_SHA"
    exit 1
  fi
  tar -C /usr/local/bin -xzf "$WGUI_TMP" wireguard-ui
  chmod +x /usr/local/bin/wireguard-ui
  rm -f "$WGUI_TMP"
fi

WGUI_HASH="$(/usr/local/bin/caddy hash-password --algorithm bcrypt --plaintext "$WGUI_PASSWORD" | tr -d '\n' | base64 -w0)"

WG_FINAL_ADDRS="$WG_ADDR_V4"
[[ -n "$WG_ADDR_V6" ]] && WG_FINAL_ADDRS="$WG_ADDR_V4,$WG_ADDR_V6"

umask 077
cat >/etc/default/wireguard-ui <<EOF
SESSION_SECRET=$(openssl rand -hex 32)
WGUI_USERNAME=$WGUI_USERNAME
WGUI_PASSWORD_HASH=$WGUI_HASH
WGUI_MANAGE_START=true
WGUI_MANAGE_RESTART=true
WGUI_SERVER_INTERFACE_ADDRESSES="$WG_FINAL_ADDRS"
WGUI_DNS="$WGUI_DNS"
WGUI_ENDPOINT_ADDRESS="$DOMAIN"
WGUI_ENDPOINT_PORT="$WGUI_ENDPOINT_PORT"
WGUI_DEFAULT_CLIENT_ALLOWED_IPS="$WGUI_DEFAULT_CLIENT_ALLOWED_IPS"
EOF
chmod 600 /etc/default/wireguard-ui
umask 022

cat >/etc/systemd/system/wireguard-ui.service <<'EOF'
[Unit]
Description=WireGuard UI
Wants=network-online.target
After=network-online.target
[Service]
EnvironmentFile=/etc/default/wireguard-ui
ExecStart=/usr/local/bin/wireguard-ui -bind-address "127.0.0.1:5000"
WorkingDirectory=/usr/local/share/wireguard-ui
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

ui_step "Configurando inyector PostUp/PostDown"
cat >/usr/local/sbin/wg-postup-inject.sh <<EOF
#!/usr/bin/env bash
set -eEuo pipefail
IFACE="\$(ip -4 route show default 2>/dev/null | awk '/default/{print \$5; exit}')"
[[ -z "\$IFACE" ]] && IFACE="${INTERFACE}"
CFG="/etc/wireguard/\${1}.conf"
[[ -f "\$CFG" ]] || exit 0

POST_UP="PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s 172.30.0.0/24 -o \${IFACE} -j MASQUERADE; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; (ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o \${IFACE} -j MASQUERADE || true)"
POST_DOWN="PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s 172.30.0.0/24 -o \${IFACE} -j MASQUERADE; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; (ip6tables -t nat -D POSTROUTING -s fd42:42:42::/64 -o \${IFACE} -j MASQUERADE || true)"

TMP="\$(mktemp)"
awk -v postup="\$POST_UP" -v postdown="\$POST_DOWN" '
  BEGIN { in_if=0; injected=0 }
  /^\[Interface\]/ { in_if=1; print; next }
  /^\[/ && \$0 !~ /^\[Interface\]/ {
    if (in_if && !injected) { print postup; print postdown; injected=1 }
    in_if=0; print; next
  }
  {
    if (in_if) {
      if (\$0 ~ /^PostUp[[:space:]]*=/) next
      if (\$0 ~ /^PostDown[[:space:]]*=/) next
    }
    print
  }
  END { if (in_if && !injected) { print postup; print postdown } }
' "\$CFG" > "\$TMP"

if ! cmp -s "\$CFG" "\$TMP"; then
  mv "\$TMP" "\$CFG"
  chmod 600 "\$CFG"
else
  rm -f "\$TMP"
fi
EOF
chmod +x /usr/local/sbin/wg-postup-inject.sh

ui_step "Configurando NAT/Forwarding"

iptables-save  > "$BACKUP_DIR/iptables.v4.backup" 2>/dev/null || true
ip6tables-save > "$BACKUP_DIR/iptables.v6.backup" 2>/dev/null || true
log_info "Backup iptables: $BACKUP_DIR"

{
  echo "net.ipv4.ip_forward=1"
  [[ -n "$WG_ADDR_V6" ]] && echo "net.ipv6.conf.all.forwarding=1"
} > /etc/sysctl.d/99-vpn.conf
sysctl -p /etc/sysctl.d/99-vpn.conf >/dev/null || true

iptables -P FORWARD DROP
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

iptables -F
iptables -t nat -F
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

if [[ -n "$WG_ADDR_V6" ]]; then
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || true
  ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o "$INTERFACE" -j MASQUERADE 2>/dev/null || true
fi

iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

iptables -t nat -A POSTROUTING -s 172.30.0.0/24 -o "$INTERFACE" -j MASQUERADE 2>/dev/null || true
netfilter-persistent save >/dev/null 2>&1 || true

cat >/etc/systemd/system/wg-quick-watcher@.path <<'EOF'
[Unit]
Description=Watch /etc/wireguard/%i.conf
[Path]
PathModified=/etc/wireguard/%i.conf
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/wg-quick-watcher@.service <<'EOF'
[Unit]
Description=Patch + Restart WireGuard %i
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-postup-inject.sh %i
ExecStart=/usr/bin/systemctl restart wg-quick@%i.service
EOF

cat >/usr/local/sbin/wg-boot-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFACE="$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}')"
[[ -z "$IFACE" ]] && exit 0
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
for _ in {1..30}; do ip link show wg0 >/dev/null 2>&1 && break; sleep 1; done
ip link show wg0 >/dev/null 2>&1 || exit 0
iptables -t nat -C POSTROUTING -s 172.30.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 172.30.0.0/24 -o "$IFACE" -j MASQUERADE
if ip -6 addr show "$IFACE" scope global | grep -q "inet6 "; then
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  ip6tables -t nat -C POSTROUTING -s fd42:42:42::/64 -o "$IFACE" -j MASQUERADE 2>/dev/null \
    || ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o "$IFACE" -j MASQUERADE 2>/dev/null || true
fi
netfilter-persistent save >/dev/null 2>&1 || true
EOF
chmod +x /usr/local/sbin/wg-boot-fix.sh

cat >/etc/systemd/system/wg-boot-fix.service <<'EOF'
[Unit]
Description=Ensure WG NAT/forward after reboot
Wants=network-online.target
After=network-online.target wireguard-ui.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-boot-fix.sh
[Install]
WantedBy=multi-user.target
EOF

ui_step "Iniciando servicios"
systemctl daemon-reload
systemctl enable --now wireguard-ui caddy wg-quick-watcher@wg0.path wg-boot-fix.service
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true

chown -R root:root /usr/local/share/wireguard-ui/db || true
systemctl restart wireguard-ui
sleep 3
systemctl restart caddy

ui_step "Verificando despliegue"
sleep 5
HEALTH=0
CODE="?"
for i in 1 2 3 4 5 6 7 8 9 10; do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://$DOMAIN/login" --max-time 10 || true)"
  if [[ "$CODE" == "200" || "$CODE" == "302" || "$CODE" == "303" ]]; then
    HEALTH=1
    break
  fi
  sleep 3
done

if [[ $HEALTH -eq 1 ]]; then
  log_success "HTTPS responde ($CODE)"
  ui "\n${UI_GREEN}Todo instalado correctamente.${UI_NC}"
  ui "${UI_GREEN}Panel: https://${DOMAIN}${UI_NC}"
  ui "${UI_GREEN}Usuario: ${WGUI_USERNAME}${UI_NC}"
  ui "${UI_YELLOW}IMPORTANTE:${UI_NC} entra al panel, crea un cliente y dale a 'APPLY CONFIG'."
  ui "${UI_YELLOW}Log: ${LOG_FILE}${UI_NC}"
else
  log_error "HTTPS no responde tras 30s (codigo=$CODE)"
  ui_err "\n${UI_RED}Advertencia: el panel no respondio tras 30s.${UI_NC}"
  ui_err "${UI_YELLOW}Revisa:${UI_NC} journalctl -u caddy -n 100 --no-pager"
  ui_err "${UI_YELLOW}Revisa:${UI_NC} journalctl -u wireguard-ui -n 100 --no-pager"
  ui_err "${UI_YELLOW}Log completo: ${LOG_FILE}${UI_NC}"
  exit 1
fi
