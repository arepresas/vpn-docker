# Homelab VPN stack

WireGuard VPN + Pi-hole DNS + web consoles. All web UIs are VPN-only by firewall design.
Example values below use `192.168.1.150` as server IP — replace with yours.

## Services

| App | URL | Notes |
|---|---|---|
| Homer (menu) | `http://192.168.1.150/` | start here |
| Pi-hole | `http://192.168.1.150:8081` | DNS + adblock, `PIHOLE_PASSWORD` |
| Portainer | `https://192.168.1.150:9443` | container management |
| Chrome | `https://192.168.1.150:3001` | web browser (HTTPS required) |
| WeTTY | `https://192.168.1.150:7681` | web SSH terminal (TLS) |
| Status (Kuma) | `http://192.168.1.150:3002` | uptime monitors |
| Backups (Backrest) | `http://192.168.1.150:9898` | restic snapshots of `./` |
| Files | `http://192.168.1.150:8082` | file manager |
| WireGuard (wg-easy UI) | `51821/udp` + UI `:8080` (LAN-only) | `10.8.0.0/24`, full tunnel via server |

Static IPs on `vpn_vpn` (`10.14.0.0/24`, gateway `.254`):
`.1` homer, `.2` pihole, `.3` chrome, `.5` portainer,
`.6` wetty, `.9` kuma, `.10` backrest, `.11` filebrowser, `.12` wg-easy.

## Deploy

```sh
cp .env.example .env   # set PIHOLE_PASSWORD, SERVERURL (no defaults, fill them all)
scp docker-compose.yml .env firewall.sh user@192.168.1.150:~/vpn-docker/
scp -r homer-assets wetty-ssl user@192.168.1.150:~/vpn-docker/   # first deploy only
ssh user@192.168.1.150
# free port 53 (Ubuntu resolved stub): DNSStubListener=no, restart systemd-resolved
cd ~/vpn-docker && docker compose up -d pihole   # DNS first
docker compose up -d
sudo ~/vpn-docker/firewall.sh   # VPN-only web UIs (+ cron @reboot, see USAGE.md)
```

Peer configs + QR codes are created in the wg-easy UI (`http://192.168.1.150:8080`, LAN-only).

## Docs

Full guide: [`USAGE.md`](USAGE.md) (secrets, Pi-hole lists, peers, DDNS, troubleshooting, backups).
