# wg-installer v3

Instalador endurecido de **WireGuard + [WireGuard-UI](https://github.com/ngoduykhanh/wireguard-ui) + Caddy** para Debian 12/13 y Ubuntu 22.04/24.04.

Genera un servidor VPN con panel web administrativo en un único dominio, con TLS automático vía Let's Encrypt.

## ⚡ Quick install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/wg-installer/main/install.sh -o /tmp/wg-install.sh && chmod 700 /tmp/wg-install.sh && sudo /tmp/wg-install.sh
```

El instalador ejecutará primero el preflight de compatibilidad y, si el VPS es apto, solicitará dominio, usuario, contraseña y correo para TLS.

Para comprobar compatibilidad sin instalar:

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/wg-installer/main/install.sh -o /tmp/wg-install.sh && chmod 700 /tmp/wg-install.sh && sudo /tmp/wg-install.sh --preflight-only
```

## Características

- **Supply-chain**: binarios de Caddy y WireGuard-UI verificados con SHA256.
- **Firewall por defecto DROP** en `INPUT` y `FORWARD`, con reglas explícitas y conntrack.
- **Backup automático** de `iptables` antes de tocar reglas (restaurables con `--uninstall`).
- **Detección automática** de interfaz por defecto, puerto SSH, soporte IPv6.
- **Dual-stack**: IPv4 + IPv6 (ULA `fd42:42:42::/64` + NAT66) cuando el server tiene IPv6 global.
- **Validación previa**: formato de dominio/email y DNS apuntando al servidor antes de pedir cert a Let's Encrypt.
- **Preflight bloqueante**: identifica OS, versión, arquitectura, virtualización, red, recursos, puertos y gestores de firewall antes de modificar el VPS.
- **Modo no interactivo** con flags — ideal para CI / automatizaciones.
- **Idempotente**: el firewall elimina duplicados y deja exactamente una regla por función.
- **Migración segura**: elimina reglas NAT66 globales creadas por versiones anteriores y las reemplaza por una regla limitada al CIDR de la VPN.
- **Aplicación segura**: el watcher valida `wg0.conf` antes de reiniciar y no modifica el archivo generado por WireGuard-UI.
- **Operación automática**: health check cada cinco minutos, respaldos diarios con retención de 14 días y actualizaciones de seguridad automáticas.
- **ACL Ecuador IPv4 opcional**: restringe puertos TCP/UDP a prefijos IPv4 ecuatorianos y actualiza la lista diariamente desde RIPEstat.
- **Uninstall** restaura iptables previos.

## Requisitos

- Debian 12/13 o Ubuntu 22.04/24.04 (amd64 o arm64)
- Acceso root
- Un dominio apuntando a la IP pública del servidor (A y/o AAAA)
- Puertos abiertos: TCP 80, TCP 443, UDP 51820

## Uso rápido (interactivo)

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/wg-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

El script pide dominio, usuario admin, contraseña y correo para Let's Encrypt.

## Validar compatibilidad sin instalar

```bash
sudo ./install.sh --preflight-only
```

El resultado será uno de estos:

- `compatible`: puede continuar con el despliegue.
- `compatible con advertencias`: puede instalar, pero se detectó una instalación previa o recursos limitados.
- `no compatible`: el instalador se detiene sin modificar el servidor.

El despliegue se bloquea cuando detecta un sistema o arquitectura no soportados, ausencia de `systemd` o ruta IPv4, menos de 1 GiB libre, ejecución dentro de un contenedor, Docker/containerd, UFW/firewalld o conflictos en los puertos requeridos. El mismo preflight se ejecuta automáticamente antes de cada instalación.

## Uso no interactivo

```bash
sudo ./install.sh \
  --non-interactive \
  --domain vpn.ejemplo.com \
  --user admin \
  --password 'SuperSecreto123' \
  --email admin@ejemplo.com
```

## Flags

| Flag | Descripción |
|---|---|
| `--domain <dominio>` | Dominio que apunta al servidor |
| `--user <usuario>` | Usuario admin del panel |
| `--password <contraseña>` | Contraseña admin |
| `--email <correo>` | Correo para Let's Encrypt |
| `--ssh-port <puerto>` | Puerto SSH (auto-detectado si se omite) |
| `--skip-dns-check` | Omitir la verificación DNS previa |
| `--preflight-only` | Validar el VPS sin instalar ni modificar |
| `--ecuador-tcp-ports <csv>` | Permitir estos puertos TCP únicamente desde IPs de Ecuador (máximo 15) |
| `--ecuador-udp-ports <csv>` | Permitir estos puertos UDP únicamente desde IPs de Ecuador (máximo 15) |
| `--non-interactive` | Falla si falta algún flag obligatorio |
| `--uninstall` | Desinstala todo y restaura iptables del backup |
| `-h / --help` | Muestra ayuda |

## Qué instala

| Componente | Versión fijada | Ubicación |
|---|---|---|
| Caddy | 2.11.4 | `/usr/local/bin/caddy` |
| WireGuard-UI | 0.6.2 | `/usr/local/bin/wireguard-ui` (UI en `127.0.0.1:5000`) |
| WireGuard | paquete del OS | `wg0` |

Unidades systemd creadas:

- `caddy.service` — reverse proxy + TLS auto
- `wireguard-ui.service` — panel web
- `wg-quick@wg0.service` — interfaz VPN
- `wg-firewall.service` — mantiene forwarding y NAT sin reglas duplicadas
- `wg-quick-watcher@wg0.path` + `@.service` — valida y aplica cambios de `wg0.conf`
- `wg-health.timer` — verifica servicios, interfaz, disco y reglas cada cinco minutos
- `wg-backup.timer` — crea un respaldo root-only diario y conserva 14 días
- `wg-ecuador-acl.timer` — actualiza diariamente los prefijos de Ecuador

## Red / NAT

- VPN IPv4: `172.30.0.0/24` (server en `.1`)
- VPN IPv6 (si el host tiene IPv6 global): `fd42:42:42::/64` (ULA + NAT66)
- DNS por defecto para clientes: Cloudflare (`1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001`)
- Puerto WireGuard: `UDP 51820`

## ACL de direcciones IP de Ecuador

Para limitar servicios concretos a direcciones asignadas a Ecuador:

```bash
sudo ./install.sh \
  --ecuador-tcp-ports 22,8443 \
  --ecuador-udp-ports 9000
```

El instalador crea el conjunto atómico `ecuador_v4`, descarga los prefijos IPv4 desde la API Country Resource List de RIPEstat y programa una actualización diaria. Antes de reemplazar la lista activa exige al menos 50 prefijos; una descarga vacía, incompleta o inválida no reemplaza la última lista válida.

Las reglas solo afectan a los puertos indicados. No incluyas `51820/UDP` salvo que quieras permitir conexiones WireGuard exclusivamente desde Ecuador. La clasificación se basa en asignaciones de los registros regionales, no en la ubicación física exacta de cada usuario; VPN, roaming, CDN o transferencias recientes pueden producir excepciones.

```bash
systemctl status wg-ecuador-acl.timer
ipset list ecuador_v4 | head
journalctl -u wg-ecuador-acl -n 50 --no-pager
```

## Primer arranque

1. Abre `https://<tu-dominio>` e inicia sesión con las credenciales que configuraste.
2. Ve a **Wireguard Clients** → **+ New Client**.
3. Rellena nombre, email (opcional), deja que WG-UI auto-asigne las IPs.
4. Click en **Submit**.
5. Vuelve al dashboard y click en **Apply Config** arriba a la derecha.
6. Descarga el `.conf` o escanea el QR desde el cliente.

> **Advertencia**: si creas clientes vía API directamente, **asigna `allocated_ips` explícitamente**. Un cliente con `allocated_ips: []` genera `AllowedIPs = ` vacío y rompe `wg-quick@wg0`.

## Seguridad

- Panel protegido con bcrypt (hash generado por Caddy) + sesión con secreto aleatorio de 32 bytes.
- Headers activos: HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy.
- `/etc/default/wireguard-ui` con `chmod 600`.
- Política `FORWARD DROP` con allowlist explícita para `wg0`.
- Política `INPUT DROP`, preservando SSH, HTTP(S), WireGuard e ICMP.
- NAT66 limitado exclusivamente al prefijo ULA de WireGuard.
- **Recomendado**: exponer el panel solo detrás de VPN una vez configurado el primer cliente (quitando 80/443 del firewall o restringiéndolos).

## Logs y debug

```bash
# Instalación
cat /root/wg-installer.log

# Servicios
systemctl status wireguard-ui caddy wg-quick@wg0
journalctl -u wireguard-ui -f
journalctl -u caddy -f
journalctl -u wg-health -n 50 --no-pager

# Estado VPN
wg show wg0
ip -br a show wg0

# Timers y respaldos
systemctl list-timers wg-health.timer wg-backup.timer
ls -lh /var/backups/wg-installer/
```

## Desinstalar

```bash
sudo ./install.sh --uninstall
```

Restaura `iptables` del backup en `/var/lib/wg-installer/backups/`.

## Licencia

MIT. Ver [LICENSE](LICENSE).
