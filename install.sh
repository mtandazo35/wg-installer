#!/bin/bash
# ================================================================= #
#  WIREGUARD PRO INSTALLER - v3 (hardened)                          #
#  Soporte: Ubuntu 24.04/22.04, Debian 13/12                        #
#  Mejoras: checksums, DNS pre-check, idempotencia, backup iptables,#
#           FORWARD DROP, non-interactive flags, uninstall.         #
# ================================================================= #

set -eEuo pipefail

LOG_FILE="/root/wg-installer.log"
STATE_DIR="/var/lib/wg-installer"
BACKUP_DIR="$STATE_DIR/backups"

CADDY_VERSION="2.11.4"
WGUI_VERSION="0.6.2"

declare -A CADDY_SHA256=(
  [amd64]="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
  [arm64]="52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904"
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
PREFLIGHT_ONLY=0
ECUADOR_TCP_PORTS=""
ECUADOR_UDP_PORTS=""

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
  --preflight-only           Validar compatibilidad sin instalar ni modificar
  --ecuador-tcp-ports <csv>  Restringir estos puertos TCP a IPs de Ecuador
  --ecuador-udp-ports <csv>  Restringir estos puertos UDP a IPs de Ecuador
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
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --ecuador-tcp-ports) ECUADOR_TCP_PORTS="$2"; shift 2 ;;
    --ecuador-udp-ports) ECUADOR_UDP_PORTS="$2"; shift 2 ;;
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
  ui "${UI_GREEN}   WIREGUARD PRO INSTALLER v3 (hardened)                      ${UI_NC}"
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

on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    ui_err "\n${UI_RED}Error durante la operacion.${UI_NC} Revisa: ${UI_YELLOW}${LOG_FILE}${UI_NC}"
  fi
}
trap on_error ERR

[[ $EUID -ne 0 ]] && { ui_err "${UI_RED}Ejecutar como root${UI_NC}"; exit 1; }

do_uninstall() {
  banner
  ui "${UI_YELLOW}Desinstalando...${UI_NC}"
  exec >>"$LOG_FILE" 2>&1

  systemctl disable --now wg-quick@wg0 wireguard-ui caddy \
    wg-quick-watcher@wg0.path wg-firewall.service wg-health.timer \
    wg-backup.timer wg-ecuador-acl.timer wg-ecuador-acl-sets.service 2>/dev/null || true

  rm -f /etc/systemd/system/wireguard-ui.service \
        /etc/systemd/system/caddy.service \
        /etc/systemd/system/wg-quick-watcher@.path \
        /etc/systemd/system/wg-quick-watcher@.service \
        /etc/systemd/system/wg-firewall.service \
        /etc/systemd/system/wg-health.service \
        /etc/systemd/system/wg-health.timer \
        /etc/systemd/system/wg-backup.service \
        /etc/systemd/system/wg-backup.timer \
        /etc/systemd/system/wg-ecuador-acl.service \
        /etc/systemd/system/wg-ecuador-acl.timer \
        /etc/systemd/system/wg-ecuador-acl-sets.service
  systemctl daemon-reload

  rm -f /usr/local/bin/caddy /usr/local/bin/wireguard-ui \
        /usr/local/sbin/wg-config-apply.sh \
        /usr/local/sbin/wg-firewall.sh \
        /usr/local/sbin/wg-health-check.sh \
        /usr/local/sbin/wg-config-backup.sh \
        /usr/local/sbin/wg-ecuador-acl.sh
  rm -rf /etc/caddy /var/lib/caddy /usr/local/share/wireguard-ui
  rm -f /etc/default/wireguard-ui /etc/default/wg-firewall \
        /etc/default/wg-ecuador-acl /etc/wireguard/wg0.conf /etc/sysctl.d/99-vpn.conf

  if [[ -f "$BACKUP_DIR/iptables.v4.backup" ]]; then
    iptables-restore < "$BACKUP_DIR/iptables.v4.backup" || true
    ui "${UI_GREEN}Restaurado iptables v4 desde backup.${UI_NC}"
  fi
  if [[ -f "$BACKUP_DIR/iptables.v6.backup" ]]; then
    ip6tables-restore < "$BACKUP_DIR/iptables.v6.backup" || true
    ui "${UI_GREEN}Restaurado iptables v6 desde backup.${UI_NC}"
  fi

  netfilter-persistent save >/dev/null 2>&1 || true
  ipset destroy ecuador_v4 2>/dev/null || true
  ipset destroy ecuador_v6 2>/dev/null || true
  ui "${UI_GREEN}Desinstalacion completada.${UI_NC}"
  exit 0
}

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
fi

declare -a PREFLIGHT_ERRORS=()
declare -a PREFLIGHT_WARNINGS=()

preflight_error() { PREFLIGHT_ERRORS+=("$1"); }
preflight_warning() { PREFLIGHT_WARNINGS+=("$1"); }

run_preflight() {
  local os_id="unknown" os_version="unknown" arch="unknown"
  local available_kb memory_kb listener process_name container_type

  ui "${UI_BLUE}Comprobando compatibilidad del VPS...${UI_NC}"

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    os_id="${ID:-unknown}"
    os_version="${VERSION_ID:-unknown}"
  else
    preflight_error "No existe /etc/os-release; no se puede identificar el sistema."
  fi

  case "${os_id}:${os_version}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) preflight_error "Sistema no soportado: ${os_id} ${os_version}. Usa Debian 12/13 o Ubuntu 22.04/24.04." ;;
  esac

  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in
    amd64|arm64|x86_64|aarch64) ;;
    *) preflight_error "Arquitectura no soportada: ${arch}. Solo amd64 y arm64." ;;
  esac

  [[ -d /run/systemd/system ]] || preflight_error "systemd no esta activo como gestor del sistema."
  command -v systemctl >/dev/null || preflight_error "No se encontro systemctl."
  command -v apt-get >/dev/null || preflight_error "No se encontro apt-get."
  command -v ip >/dev/null || preflight_error "No se encontro iproute2; no se puede detectar la red."

  if command -v ip >/dev/null && ! ip -4 route show default 2>/dev/null | grep -q '^default'; then
    preflight_error "No existe una ruta IPv4 predeterminada."
  fi

  available_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || available_kb=0
  (( available_kb >= 1048576 )) || preflight_error "Se requiere al menos 1 GiB libre en /."

  memory_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "$memory_kb" =~ ^[0-9]+$ ]] || memory_kb=0
  (( memory_kb >= 524288 )) || preflight_warning "Hay menos de 512 MiB de RAM; el servicio puede funcionar con poca holgura."

  container_type="$(systemd-detect-virt --container 2>/dev/null || true)"
  if [[ -n "$container_type" && "$container_type" != none ]]; then
    preflight_error "Entorno contenedorizado detectado (${container_type}); se requiere un VPS/VM con NET_ADMIN y kernel WireGuard."
  fi

  if systemctl is-active --quiet docker.service 2>/dev/null || systemctl is-active --quiet containerd.service 2>/dev/null; then
    preflight_error "Docker/containerd esta activo; reconstruir iptables podria interrumpir sus redes."
  fi
  if systemctl is-active --quiet ufw.service 2>/dev/null; then
    preflight_error "UFW esta activo; debe deshabilitarse o integrarse antes del despliegue."
  fi
  if systemctl is-active --quiet firewalld.service 2>/dev/null; then
    preflight_error "firewalld esta activo; debe deshabilitarse o integrarse antes del despliegue."
  fi

  if command -v ss >/dev/null; then
    while IFS= read -r listener; do
      process_name="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$listener")"
      case "$process_name" in
        caddy|wireguard-ui|"") ;;
        *) preflight_error "Puerto web 80/443 ocupado por ${process_name}; Caddy no podra iniciarse." ;;
      esac
    done < <(ss -H -lntp '( sport = :80 or sport = :443 )' 2>/dev/null || true)

    listener="$(ss -H -lnup '( sport = :51820 )' 2>/dev/null || true)"
    if [[ -n "$listener" ]] && ! ip link show wg0 >/dev/null 2>&1; then
      preflight_error "UDP 51820 ya esta ocupado por otro proceso."
    fi
  else
    preflight_warning "No se encontro ss; los conflictos de puertos se revisaran despues de instalar dependencias."
  fi

  if [[ -e /etc/wireguard/wg0.conf || -e /etc/caddy/Caddyfile || -e /etc/default/wireguard-ui ]]; then
    preflight_warning "Se detecto una instalacion previa; se crearan respaldos y se actualizaran sus componentes."
  fi

  ui "${UI_YELLOW}Sistema:${UI_NC} ${os_id} ${os_version}; arquitectura ${arch}"
  for listener in "${PREFLIGHT_WARNINGS[@]}"; do ui "${UI_YELLOW}ADVERTENCIA:${UI_NC} $listener"; done
  for listener in "${PREFLIGHT_ERRORS[@]}"; do ui_err "${UI_RED}NO COMPATIBLE:${UI_NC} $listener"; done

  if (( ${#PREFLIGHT_ERRORS[@]} > 0 )); then
    ui_err "${UI_RED}Resultado: no se puede desplegar de forma segura.${UI_NC}"
    return 1
  fi

  if (( ${#PREFLIGHT_WARNINGS[@]} > 0 )); then
    ui "${UI_YELLOW}Resultado: compatible con advertencias.${UI_NC}"
  else
    ui "${UI_GREEN}Resultado: compatible.${UI_NC}"
  fi
}

banner
run_preflight
if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  exit 0
fi
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

detect_os_ui
ui "=============================================="

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_port_list() {
  local value="$1" item count=0
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  IFS=',' read -ra items <<<"$value"
  for item in "${items[@]}"; do
    (( item >= 1 && item <= 65535 )) || return 1
    count=$((count + 1))
  done
  (( count <= 15 ))
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
validate_port_list "$ECUADOR_TCP_PORTS" || { ui_err "${UI_RED}Lista TCP invalida (maximo 15 puertos): $ECUADOR_TCP_PORTS${UI_NC}"; exit 2; }
validate_port_list "$ECUADOR_UDP_PORTS" || { ui_err "${UI_RED}Lista UDP invalida (maximo 15 puertos): $ECUADOR_UDP_PORTS${UI_NC}"; exit 2; }

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
  util-linux unattended-upgrades ipset jq
)
if [[ "$OS_FAMILY" == "debian" ]] && ! systemctl is-active --quiet systemd-resolved; then
  PKGS+=(resolvconf)
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}"
systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
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
WGUI_MANAGE_START=false
WGUI_MANAGE_RESTART=false
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

ui_step "Configurando firewall idempotente"

[[ -f "$BACKUP_DIR/iptables.v4.backup" ]] || iptables-save > "$BACKUP_DIR/iptables.v4.backup" 2>/dev/null || true
[[ -f "$BACKUP_DIR/iptables.v6.backup" ]] || ip6tables-save > "$BACKUP_DIR/iptables.v6.backup" 2>/dev/null || true
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
iptables -P INPUT DROP

if [[ -n "$WG_ADDR_V6" ]]; then
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || true
  ip6tables -P INPUT DROP 2>/dev/null || true
  ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o "$INTERFACE" -j MASQUERADE 2>/dev/null || true
fi

iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

cat >/etc/default/wg-firewall <<EOF
WG_INTERFACE=wg0
WAN_INTERFACE=$INTERFACE
WG_IPV4_CIDR=172.30.0.0/24
WG_IPV6_CIDR=fd42:42:42::/64
ENABLE_IPV6=$HAS_IPV6
EOF
chmod 600 /etc/default/wg-firewall

cat >/usr/local/sbin/wg-firewall.sh <<'EOF'
#!/usr/bin/env bash
set -eEuo pipefail
. /etc/default/wg-firewall
action="${1:-apply}"

delete_all() {
  local family="$1" table="$2"; shift 2
  while "$family" -w -t "$table" -C "$@" 2>/dev/null; do
    "$family" -w -t "$table" -D "$@"
  done
}

remove_rules() {
  delete_all iptables filter FORWARD -i "$WG_INTERFACE" -j ACCEPT
  delete_all iptables filter FORWARD -o "$WG_INTERFACE" -j ACCEPT
  delete_all iptables nat POSTROUTING -s "$WG_IPV4_CIDR" -o "$WAN_INTERFACE" -j MASQUERADE
  if [[ "$ENABLE_IPV6" == 1 ]]; then
    delete_all ip6tables filter FORWARD -i "$WG_INTERFACE" -j ACCEPT
    delete_all ip6tables filter FORWARD -o "$WG_INTERFACE" -j ACCEPT
    # Migra instalaciones v2: elimina NAT66 global sin CIDR de origen.
    delete_all ip6tables nat POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE
    delete_all ip6tables nat POSTROUTING -s "$WG_IPV6_CIDR" -o "$WAN_INTERFACE" -j MASQUERADE
  fi
}

remove_rules
if [[ "$action" == apply ]]; then
  iptables -w -A FORWARD -i "$WG_INTERFACE" -j ACCEPT
  iptables -w -A FORWARD -o "$WG_INTERFACE" -j ACCEPT
  iptables -w -t nat -A POSTROUTING -s "$WG_IPV4_CIDR" -o "$WAN_INTERFACE" -j MASQUERADE
  if [[ "$ENABLE_IPV6" == 1 ]]; then
    ip6tables -w -A FORWARD -i "$WG_INTERFACE" -j ACCEPT
    ip6tables -w -A FORWARD -o "$WG_INTERFACE" -j ACCEPT
    ip6tables -w -t nat -A POSTROUTING -s "$WG_IPV6_CIDR" -o "$WAN_INTERFACE" -j MASQUERADE
  fi
fi
EOF
chmod 750 /usr/local/sbin/wg-firewall.sh

cat >/etc/systemd/system/wg-firewall.service <<'EOF'
[Unit]
Description=Idempotent WireGuard forwarding and NAT
Wants=network-online.target
After=network-online.target netfilter-persistent.service
Before=wg-quick@wg0.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wg-firewall.sh apply
ExecReload=/usr/local/sbin/wg-firewall.sh apply
ExecStop=/usr/local/sbin/wg-firewall.sh remove
[Install]
WantedBy=multi-user.target
EOF

/usr/local/sbin/wg-firewall.sh apply
netfilter-persistent save >/dev/null 2>&1 || true

cat >/etc/default/wg-ecuador-acl <<EOF
ECUADOR_TCP_PORTS="$ECUADOR_TCP_PORTS"
ECUADOR_UDP_PORTS="$ECUADOR_UDP_PORTS"
ECUADOR_ACL_URL="https://stat.ripe.net/data/country-resource-list/data.json?resource=EC&v4_format=prefix"
EOF
chmod 600 /etc/default/wg-ecuador-acl

cat >/usr/local/sbin/wg-ecuador-acl.sh <<'EOF'
#!/usr/bin/env bash
set -eEuo pipefail
. /etc/default/wg-ecuador-acl

state_dir=/var/lib/wg-installer/ecuador-acl
v4_file="$state_dir/ipv4.txt"
v6_file="$state_dir/ipv6.txt"
mode="${1:-update}"

remove_input_jumps() {
  local family="$1" chain="$2" line
  while line=$("$family" -L INPUT --line-numbers -n | awk -v target="$chain" '$2 == target {print $1; exit}') && [[ -n "$line" ]]; do
    "$family" -w -D INPUT "$line"
  done
}

remove_rules() {
  remove_input_jumps iptables WG_EC4
  remove_input_jumps ip6tables WG_EC6
  iptables -w -F WG_EC4 2>/dev/null || true
  iptables -w -X WG_EC4 2>/dev/null || true
  ip6tables -w -F WG_EC6 2>/dev/null || true
  ip6tables -w -X WG_EC6 2>/dev/null || true
}

load_sets() {
  local source_v4="$1" source_v6="$2"
  ipset create ecuador_v4 hash:net family inet maxelem 20000 -exist
  ipset create ecuador_v6 hash:net family inet6 maxelem 20000 -exist
  ipset create ecuador_v4_new hash:net family inet maxelem 20000 -exist
  ipset create ecuador_v6_new hash:net family inet6 maxelem 20000 -exist
  ipset flush ecuador_v4_new
  ipset flush ecuador_v6_new
  awk '{print "add ecuador_v4_new " $0}' "$source_v4" | ipset restore
  awk '{print "add ecuador_v6_new " $0}' "$source_v6" | ipset restore
  ipset swap ecuador_v4_new ecuador_v4
  ipset swap ecuador_v6_new ecuador_v6
  ipset destroy ecuador_v4_new
  ipset destroy ecuador_v6_new
}

apply_rules() {
  remove_rules
  iptables -w -N WG_EC4
  ip6tables -w -N WG_EC6
  iptables -w -A WG_EC4 -m set --match-set ecuador_v4 src -j ACCEPT
  iptables -w -A WG_EC4 -j DROP
  ip6tables -w -A WG_EC6 -m set --match-set ecuador_v6 src -j ACCEPT
  ip6tables -w -A WG_EC6 -j DROP
  if [[ -n "$ECUADOR_TCP_PORTS" ]]; then
    iptables -w -I INPUT 1 -p tcp -m multiport --dports "$ECUADOR_TCP_PORTS" -j WG_EC4
    ip6tables -w -I INPUT 1 -p tcp -m multiport --dports "$ECUADOR_TCP_PORTS" -j WG_EC6
  fi
  if [[ -n "$ECUADOR_UDP_PORTS" ]]; then
    iptables -w -I INPUT 1 -p udp -m multiport --dports "$ECUADOR_UDP_PORTS" -j WG_EC4
    ip6tables -w -I INPUT 1 -p udp -m multiport --dports "$ECUADOR_UDP_PORTS" -j WG_EC6
  fi
}

if [[ "$mode" == --remove ]]; then
  remove_rules
  exit 0
fi

if [[ "$mode" == --sets-only ]]; then
  [[ -s "$v4_file" && -s "$v6_file" ]]
  load_sets "$v4_file" "$v6_file"
  exit 0
fi

tmp_dir=$(mktemp -d)
trap 'ipset destroy ecuador_v4_new 2>/dev/null || true; ipset destroy ecuador_v6_new 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT
curl --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 -fsSL "$ECUADOR_ACL_URL" -o "$tmp_dir/resources.json"
jq -e '(.status == "ok") and ((.data.resource | ascii_upcase) == "EC")' "$tmp_dir/resources.json" >/dev/null
jq -er '.data.resources.ipv4[]' "$tmp_dir/resources.json" | sort -u > "$tmp_dir/ipv4.txt"
jq -er '.data.resources.ipv6[]' "$tmp_dir/resources.json" | sort -u > "$tmp_dir/ipv6.txt"
! grep -qxF '0.0.0.0/0' "$tmp_dir/ipv4.txt"
! grep -qxF '::/0' "$tmp_dir/ipv6.txt"
v4_count=$(wc -l < "$tmp_dir/ipv4.txt")
v6_count=$(wc -l < "$tmp_dir/ipv6.txt")
(( v4_count >= 50 )) || { echo "Ecuador IPv4 list too small: $v4_count" >&2; exit 1; }
(( v6_count >= 10 )) || { echo "Ecuador IPv6 list too small: $v6_count" >&2; exit 1; }
load_sets "$tmp_dir/ipv4.txt" "$tmp_dir/ipv6.txt"
install -d -m 700 "$state_dir"
install -m 600 "$tmp_dir/ipv4.txt" "$v4_file"
install -m 600 "$tmp_dir/ipv6.txt" "$v6_file"
date -u +%Y-%m-%dT%H:%M:%SZ > "$state_dir/last-success"
chmod 600 "$state_dir/last-success"
apply_rules
logger -t wg-ecuador-acl "Updated Ecuador ACL: $v4_count IPv4 prefixes, $v6_count IPv6 prefixes"
EOF
chmod 750 /usr/local/sbin/wg-ecuador-acl.sh

cat >/etc/systemd/system/wg-ecuador-acl-sets.service <<'EOF'
[Unit]
Description=Restore Ecuador IP sets before persistent firewall rules
DefaultDependencies=no
After=local-fs.target
Before=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-ecuador-acl.sh --sets-only
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/wg-ecuador-acl.service <<'EOF'
[Unit]
Description=Update Ecuador IPv4 and IPv6 ACL sets
Wants=network-online.target
After=network-online.target wg-ecuador-acl-sets.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-ecuador-acl.sh update
EOF

cat >/etc/systemd/system/wg-ecuador-acl.timer <<'EOF'
[Unit]
Description=Daily update of Ecuador IP ACL sets

[Timer]
OnBootSec=10min
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/wg-quick-watcher@.path <<'EOF'
[Unit]
Description=Watch /etc/wireguard/%i.conf
[Path]
PathModified=/etc/wireguard/%i.conf
Unit=wg-quick-watcher@%i.service
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/wg-quick-watcher@.service <<'EOF'
[Unit]
Description=Validate and apply WireGuard %i configuration
After=wg-firewall.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-config-apply.sh %i
EOF

cat >/usr/local/sbin/wg-config-apply.sh <<'EOF'
#!/usr/bin/env bash
set -eEuo pipefail
iface="${1:?interface required}"
cfg="/etc/wireguard/${iface}.conf"
exec 9>"/run/lock/wg-config-${iface}.lock"
flock -w 30 9
sleep 1
[[ -s "$cfg" ]]
chmod 600 "$cfg"
wg-quick strip "$cfg" >/dev/null
systemctl restart "wg-quick@${iface}.service"
EOF
chmod 750 /usr/local/sbin/wg-config-apply.sh

ui_step "Configurando monitoreo y respaldos"
cat >/usr/local/sbin/wg-health-check.sh <<'EOF'
#!/usr/bin/env bash
set -eEuo pipefail
failed=0
for unit in wg-quick@wg0 wireguard-ui caddy wg-firewall; do
  systemctl is-active --quiet "$unit" || { logger -p daemon.err -t wg-health "$unit is not active"; failed=1; }
done
ip link show wg0 >/dev/null 2>&1 || { logger -p daemon.err -t wg-health "wg0 is missing"; failed=1; }
[[ $(df --output=pcent / | tail -1 | tr -dc '0-9') -lt 85 ]] || { logger -p daemon.warning -t wg-health "root filesystem usage is at least 85%"; failed=1; }
[[ $(iptables -S FORWARD | grep -c -- '-i wg0 -j ACCEPT' || true) -eq 1 ]] || { logger -p daemon.err -t wg-health "unexpected IPv4 forwarding rule count"; failed=1; }
[[ $(iptables -t nat -S POSTROUTING | grep -c -- '-s 172.30.0.0/24 .* -j MASQUERADE' || true) -eq 1 ]] || { logger -p daemon.err -t wg-health "unexpected IPv4 NAT rule count"; failed=1; }
[[ $(ip6tables -t nat -S POSTROUTING | grep -c -- "^-A POSTROUTING -o .* -j MASQUERADE$" || true) -eq 0 ]] || { logger -p daemon.err -t wg-health "unsafe legacy NAT66 rule detected"; failed=1; }
if [[ -r /etc/default/wg-ecuador-acl ]]; then
  . /etc/default/wg-ecuador-acl
  if [[ -n "${ECUADOR_TCP_PORTS:-}" || -n "${ECUADOR_UDP_PORTS:-}" ]]; then
    systemctl is-active --quiet wg-ecuador-acl.timer || { logger -p daemon.err -t wg-health "Ecuador ACL timer is not active"; failed=1; }
    [[ $(ipset list ecuador_v4 2>/dev/null | awk '/Number of entries:/ {print $4}') -ge 50 ]] || { logger -p daemon.err -t wg-health "Ecuador IPv4 set is missing or too small"; failed=1; }
    [[ $(ipset list ecuador_v6 2>/dev/null | awk '/Number of entries:/ {print $4}') -ge 10 ]] || { logger -p daemon.err -t wg-health "Ecuador IPv6 set is missing or too small"; failed=1; }
    find /var/lib/wg-installer/ecuador-acl/last-success -mmin -2880 -print -quit 2>/dev/null | grep -q . || { logger -p daemon.err -t wg-health "Ecuador ACL has not updated successfully in 48 hours"; failed=1; }
  fi
fi
exit "$failed"
EOF
chmod 750 /usr/local/sbin/wg-health-check.sh

cat >/etc/systemd/system/wg-health.service <<'EOF'
[Unit]
Description=WireGuard stack health check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-health-check.sh
EOF
cat >/etc/systemd/system/wg-health.timer <<'EOF'
[Unit]
Description=Run WireGuard health check every five minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat >/usr/local/sbin/wg-config-backup.sh <<'EOF'
#!/usr/bin/env bash
set -eEuo pipefail
dest=/var/backups/wg-installer
stamp=$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 "$dest"
umask 077
tar -czf "$dest/config-${stamp}.tar.gz" \
  /etc/wireguard /etc/default/wireguard-ui /etc/default/wg-firewall \
  /etc/default/wg-ecuador-acl \
  /etc/caddy /etc/iptables /etc/systemd/system/wg-*.service \
  /etc/systemd/system/wg-*.timer /etc/systemd/system/wg-*.path \
  /etc/systemd/system/wireguard-ui.service /etc/systemd/system/caddy.service \
  /usr/local/share/wireguard-ui/db 2>/dev/null
find "$dest" -type f -name 'config-*.tar.gz' -mtime +14 -delete
EOF
chmod 750 /usr/local/sbin/wg-config-backup.sh

cat >/etc/systemd/system/wg-backup.service <<'EOF'
[Unit]
Description=Backup WireGuard stack configuration
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-config-backup.sh
EOF
cat >/etc/systemd/system/wg-backup.timer <<'EOF'
[Unit]
Description=Daily WireGuard configuration backup
[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
EOF

ui_step "Iniciando servicios"
systemctl daemon-reload
systemctl enable --now wireguard-ui caddy wg-firewall.service \
  wg-quick-watcher@wg0.path wg-health.timer wg-backup.timer
if [[ -n "$ECUADOR_TCP_PORTS" || -n "$ECUADOR_UDP_PORTS" ]]; then
  /usr/local/sbin/wg-ecuador-acl.sh update
  systemctl enable --now wg-ecuador-acl-sets.service wg-ecuador-acl.timer
else
  /usr/local/sbin/wg-ecuador-acl.sh --remove
  systemctl disable --now wg-ecuador-acl.timer wg-ecuador-acl-sets.service 2>/dev/null || true
fi
netfilter-persistent save >/dev/null 2>&1 || true
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
/usr/local/sbin/wg-config-backup.sh

chown -R root:root /usr/local/share/wireguard-ui/db || true
systemctl restart wireguard-ui
sleep 3
systemctl restart caddy

ui_step "Verificando despliegue"
sleep 5
HEALTH=0
CODE="?"
for _ in 1 2 3 4 5 6 7 8 9 10; do
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
