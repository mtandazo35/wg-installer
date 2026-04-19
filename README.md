# wg-installer

Instalador endurecido de **WireGuard + [WireGuard-UI](https://github.com/ngoduykhanh/wireguard-ui) + Caddy** para Debian 12/13 y Ubuntu 22.04/24.04.

Genera un servidor VPN con panel web administrativo en un único dominio, con TLS automático vía Let's Encrypt.

## Características

- **Supply-chain**: binarios de Caddy y WireGuard-UI verificados con SHA256.
- **Firewall por defecto DROP** en `FORWARD` + reglas explícitas con conntrack.
- **Backup automático** de `iptables` antes de tocar reglas (restaurables con `--uninstall`).
- **Detección automática** de interfaz por defecto, puerto SSH, soporte IPv6.
- **Dual-stack**: IPv4 + IPv6 (ULA `fd42:42:42::/64` + NAT66) cuando el server tiene IPv6 global.
- **Validación previa**: formato de dominio/email y DNS apuntando al servidor antes de pedir cert a Let's Encrypt.
- **Modo no interactivo** con flags — ideal para CI / automatizaciones.
- **Idempotente**: re-ejecutar no redescarga binarios si la versión ya está instalada.
- **Watchers systemd** que re-inyectan `PostUp/PostDown` en `wg0.conf` cada vez que WireGuard-UI lo reescribe.
- **Uninstall** restaura iptables previos.

## Requisitos

- Debian 12/13 o Ubuntu 22.04/24.04 (amd64 o arm64)
- Acceso root
- Un dominio apuntando a la IP pública del servidor (A y/o AAAA)
- Puertos abiertos: TCP 80, TCP 443, UDP 51820

## Uso rápido (interactivo)

```bash
curl -fsSL https://raw.githubusercontent.com/manolinxxx/wg-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

El script pide dominio, usuario admin, contraseña y correo para Let's Encrypt.

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
| `--non-interactive` | Falla si falta algún flag obligatorio |
| `--uninstall` | Desinstala todo y restaura iptables del backup |
| `-h / --help` | Muestra ayuda |

## Qué instala

| Componente | Versión fijada | Ubicación |
|---|---|---|
| Caddy | 2.11.2 | `/usr/local/bin/caddy` |
| WireGuard-UI | 0.6.2 | `/usr/local/bin/wireguard-ui` (UI en `127.0.0.1:5000`) |
| WireGuard | paquete del OS | `wg0` |

Unidades systemd creadas:

- `caddy.service` — reverse proxy + TLS auto
- `wireguard-ui.service` — panel web
- `wg-quick@wg0.service` — interfaz VPN
- `wg-quick-watcher@wg0.path` + `@.service` — re-inyecta PostUp/PostDown al cambiar `wg0.conf`
- `wg-boot-fix.service` — asegura NAT/forwarding tras reboot

## Red / NAT

- VPN IPv4: `172.30.0.0/24` (server en `.1`)
- VPN IPv6 (si el host tiene IPv6 global): `fd42:42:42::/64` (ULA + NAT66)
- DNS por defecto para clientes: Cloudflare (`1.1.1.1`, `1.0.0.1`, `2606:4700:4700::1111`, `2606:4700:4700::1001`)
- Puerto WireGuard: `UDP 51820`

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
- **Recomendado**: exponer el panel solo detrás de VPN una vez configurado el primer cliente (quitando 80/443 del firewall o restringiéndolos).

## Logs y debug

```bash
# Instalación
cat /root/wg-installer.log

# Servicios
systemctl status wireguard-ui caddy wg-quick@wg0
journalctl -u wireguard-ui -f
journalctl -u caddy -f

# Estado VPN
wg show wg0
ip -br a show wg0
```

## Desinstalar

```bash
sudo ./install.sh --uninstall
```

Restaura `iptables` del backup en `/var/lib/wg-installer/backups/`.

## Licencia

MIT. Ver [LICENSE](LICENSE).
