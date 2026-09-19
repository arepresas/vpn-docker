# VPN Usage (Homelab)

WireGuard VPN + Pi-hole DNS + web consoles stack.
Entry point: Homer menu `http://192.168.1.150/` (port 80, no port typing).

> Conventions: `192.168.1.150` = server LAN IP, `user`/`vpnuser` = server SSH user,
> `vpn.example.com` = public DDNS name. Replace with yours.

- Host: `192.168.1.150` (`orangepi3-lts`, `aarch64` Linux, Docker + Compose v2)
- Project: `vpn` in `~/vpn-docker/docker-compose.yml` + `.env` on Homelab, mirrored locally
- WireGuard: `ghcr.io/wg-easy/wg-easy:15`, host port `51821/udp` -> container `51821/udp`, clients `10.8.0.0/24`, UI `http://192.168.1.150:8080` (LAN-only). Container itself is `10.14.0.12` on bridge `vpn` so peers use Pi-hole DNS
- Pi-hole: `pihole/pihole:latest` (v6), static `10.14.0.2` on bridge `vpn_vpn` (`10.14.0.0/24`), DNS `53`, admin `http://192.168.1.150:8081`
- Portainer: `portainer/portainer-ce:latest`, admin `https://192.168.1.150:9443`, manages local Docker via socket
- WeTTY: `wettyoss/wetty:latest`, web SSH terminal `https://192.168.1.150:7681` (TLS), login `vpnuser` + host password
- Chrome: `lscr.io/linuxserver/chromium:latest` (`10.14.0.3`), `https://192.168.1.150:3001` (HTTPS required)
- Peers are created in the wg-easy UI (QR + `.conf` download per device), subnet `10.8.0.0/24`
- Homer: `b4bz/homer:latest` (`10.14.0.1`), main menu `http://192.168.1.150/` with icon links to all apps
- Uptime Kuma: `louislam/uptime-kuma:2` (`10.14.0.9`), monitors `http://192.168.1.150:3002`
- Backrest: `garethgeorge/backrest:latest` (`10.14.0.10`), restic backups `http://192.168.1.150:9898`, backs up `./` stack dir
- Filebrowser: `filebrowser/filebrowser:latest` (`10.14.0.11`), files `http://192.168.1.150:8082`, serves `./filebrowser-srv/`
- Static IPs on `vpn_vpn` (gateway moved to `.254` so `.1` is free): `.1` homer, `.2` pihole, `.3` chrome, `.5` portainer, `.6` wetty, `.9` kuma, `.10` backrest, `.11` filebrowser, `.12` wg-easy
- DNS for peers AND all containers: Pi-hole `10.14.0.2`, full tunnel `AllowedIPs = 0.0.0.0/0` (exit via Homelab, set per client in the UI)
- Blocklists: StevenBlack + OISD Big + Hagezi Pro + AdGuard DNS (~450k unique domains)

## 0. Secrets (.env)

All secrets and site config live in `.env` (gitignored, never commit). Copy and edit:

```sh
cp .env.example .env
# set PIHOLE_PASSWORD, SERVERURL, WGEASY_UI_PORT
```

| Var | Use |
|---|---|
| `PIHOLE_PASSWORD` | Pi-hole web admin + API |
| `SERVERURL` | `192.168.1.150` LAN test, DDNS name for external (used as WG_HOST in the UI wizard) |
| `SERVERPORT` | `51821` host UDP port |
| `WGEASY_UI_PORT` | `8080` host TCP port for the wg-easy UI (LAN-only, never forward) |
| `TZ/PUID/PGID` | timezone + file ownership |
| `PIHOLE_WEB_PORT/PIHOLE_HTTPS_PORT` | `8081/8443` host ports |
| `PORTAINER_PORT/PORTAINER_EDGE_PORT` | `9443/8000` host ports |
| `WETTY_PORT/WETTY_SSH_HOST/WETTY_SSH_USER` | `7681/192.168.1.150/vpnuser` |
| `HOMER_PORT` | `80` host port (plain `http://192.168.1.150/`) |
| `KUMA_PORT/BACKREST_PORT/FILEBROWSER_PORT` | `3002/9898/8082` host ports |

Compose has no defaults: every `${VAR}` must be set in `.env`, unnamed values
resolve empty and the service misbehaves - copy `.env.example` and fill it.

Deploy everything (order matters: DNS first):

```sh
scp docker-compose.yml .env user@192.168.1.150:~/vpn-docker/
scp -r homer-assets wetty-ssl user@192.168.1.150:~/vpn-docker/  # first deploy only
ssh user@192.168.1.150
cd ~/vpn-docker && docker compose up -d pihole   # DNS base first
docker compose up -d   # rest: wgeasy chrome portainer wetty homer
```

## 1. Deploy (fresh host)

> Host needs port 53 free: Ubuntu `systemd-resolved` stub blocks it.
> One-time, reversible (`/etc/systemd/resolved.conf.bak` kept):
>
> ```sh
> sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
> # set DNSStubListener=no and DNS=192.168.1.1 1.1.1.1
> sudo systemctl restart systemd-resolved
> ```

```sh
scp docker-compose.yml .env user@192.168.1.150:~/vpn-docker/
scp -r homer-assets wetty-ssl user@192.168.1.150:~/vpn-docker/  # first deploy only
ssh user@192.168.1.150
cd ~/vpn-docker && docker compose up -d pihole   # DNS base first
docker compose up -d                            # everything else
docker logs wgeasy --tail 50
docker compose ps
ss -tulpn | grep -E '51821|:53 '
```

VPN-only firewall (host `iptables`, §10):

```sh
scp firewall.sh user@192.168.1.150:~/vpn-docker/
ssh user@192.168.1.150
chmod +x ~/vpn-docker/firewall.sh
sudo ~/vpn-docker/firewall.sh
(crontab -l 2>/dev/null | grep -v 'vpn-docker/firewall.sh'; echo '@reboot sleep 30 && $HOME/vpn-docker/firewall.sh') | crontab -
```

> Big images on small ARM boards: chromium ~3.2GB, wetty ~600MB. Pulls take a while.
> Run long pulls detached: `nohup docker compose up -d chrome > /tmp/up.log 2>&1 &`.

Peers live in the wg-easy UI, not on disk: open `http://192.168.1.150:8080`,
New Client per device, QR/`.conf` straight to the device. Server state persists
in the `./wgeasy-data/` bind mount (back it up).

## 2. Pi-hole

Admin: `http://192.168.1.150:8081` (password = `PIHOLE_PASSWORD` in `.env`).
Upstreams: `1.1.1.1;1.0.0.1;8.8.8.8`. DNS listens on all interfaces
(`FTLCONF_dns_listeningMode=ALL`) so VPN peers (`10.8.0.0/24`) and
containers reach `10.14.0.2`.

Blocklists + allowlist are managed by `./pihole-lists.sh` (idempotent, run after `up`).
Do NOT hand-edit `gravity.db` anymore. Weekly updates are automatic by Pi-hole.

```sh
cd ~/vpn-docker
docker compose up -d pihole
./pihole-lists.sh                    # stage base lists + allowlist (no download yet)
./pihole-lists.sh --update-now       # rebuild gravity (minutes, log /tmp/gravity.log)
./pihole-lists.sh --with-threat --update-now  # + small threat feeds (see below)
./pihole-lists.sh --with-extra --update-now   # + 5 low-risk extras (fakenews, SmartTV...)
```

| Tier | Lists | Why |
|---|---|---|
| Base (default) | StevenBlack unified, OISD Small, OISD Big, Hagezi Multi Pro (**adblock** format), AdGuard DNS filter | Balanced ~500-600k domains, low false positives. OISD Small forgives what Big overblocks |
| Threat (opt-in `--with-threat`) | URLHaus hostfile, ThreatFox hostfile, Hagezi most-abused-TLDs | Small, high-value malware/C2/phishing. Skipped by default for RAM |
| Extra (opt-in `--with-extra`) | StevenBlack fakenews, SmartTV Perflyst+Dandelion (`filter_7`), RPiList malware, RPiList EasyList extended, uBlock badware (`filter_50`) | Low FP, verified Pi-hole format. No Spanish hosts list exists in the registry - Spanish cosmetic filtering belongs in the browser (uBlock), not DNS |
| NOT enabled (heavy) | Hagezi TIF full (~2M, needs >=2GB), Pro++ / Ultimate, 1Hosts Xtra (~1.1M), Tempest phishing+malware (~1M) | Too big/aggressive for Orange Pi and daily use. Enable one at a time only if you test breakage |

> Format matters with Hagezi: Pi-hole needs the **adblock** files
> (`.../adblock/pro.txt`), NOT `wildcard/*` (that's for Blocky/YogaDNS).
> The old `wildcard/pro.txt` reference in this doc was wrong and is fixed in the script.

Allowlist (exact-allow, auto-applied by the script, Pi-hole `domainlist.type=0`):

- Connectivity/auth (never break): `www.msftncsi.com`, `ctldl.windowsupdate.com`, `download.windowsupdate.com`, `login.microsoftonline.com`, `outlook.office365.com`, `teams.microsoft.com`, `connectivitycheck.gstatic.com`, `play.googleapis.com`
- Media: `spclient.wg.spotify.com`, `apresolve.spotify.com`, `api-tv.spotify.com`, `open.spotify.com`, `netflix.com`, `primevideo.com`, `disneyplus.com`, `amazon.com`
- Apple/Xbox: `mask.icloud.com`, `mask-h2.icloud.com`, `xboxlive.com`, `attestation/title.auth.xboxlive.com`
- Curated from: GoodnessJSON PiHole-Whitelist (v6 allowlist), anudeepND original, Pi-hole discourse commonly-whitelisted, O365 whitelist, Spotify/Xbox threads

Manual one-offs (no script needed, container running):

```sh
docker exec pihole pihole allow example.com      # allow exact
docker exec pihole pihole deny example.com       # exact deny
docker exec pihole pihole allow remove example.com
```

Rollback: `pihole-etc/gravity.db.bak` is kept on first script run.
`docker stop pihole && cp pihole-etc/gravity.db.bak pihole-etc/gravity.db && docker start pihole`.

Verify filtering (from Homelab):

```sh
docker exec chrome getent hosts google.com       # resolves = DNS OK
docker exec chrome getent hosts doubleclick.net  # 0.0.0.0 = blocked
```

## 3. Portainer

Manage all containers at `https://192.168.1.150:9443` (self-signed, accept).
First visit creates the admin user (do it within minutes, fresh install).
Local Docker auto-attached via `/var/run/docker.sock`: containers, images,
networks, volumes, logs, console, compose stacks.

## 4. WeTTY (web terminal)

Generate once per install (self-signed, 825 days, SAN = server IP):

```sh
mkdir -p wetty-ssl
openssl req -x509 -newkey rsa:2048 -keyout wetty-ssl/key.pem -out wetty-ssl/cert.pem \
  -days 825 -nodes -subj "/CN=homelab" \
  -addext "subjectAltName=IP:192.168.1.150,DNS:homelab"  # replace with your IP/hostname
```

Open `https://192.168.1.150:7681` (self-signed cert from `./wetty-ssl/`, accept once),
user `vpnuser`, password = host SSH password.
Full host shell in browser (same as SSH). Reachable only over VPN (+ localhost)
by firewall design.

## 5. Connect (wg-easy UI)

UI: `http://192.168.1.150:8080` (LAN-only, plain HTTP needs `INSECURE=true`
which the compose already sets - never expose this port on the router).

1. Log in (admin password defined in the first-run wizard).
2. Interface settings: `WG_HOST` = `192.168.1.150` on LAN, DDNS name for
   external; default DNS for new clients = `10.14.0.2` (Pi-hole, reachable
   because the container sits on the `vpn` bridge as `10.14.0.12`).
3. New Client per device (one peer per device, never share a `.conf`):
   phone, laptop, Asus router, etc. Full tunnel = `AllowedIPs 0.0.0.0/0`.

Mobile: WireGuard app -> `+` -> `Scan QR Code` -> activate.
Desktop: WireGuard app -> `Import tunnel from file` -> select `.conf` -> `Activate`.
Ubuntu 24.04 GUI: `Settings > Network > VPN > Import from file`.
Asus RT-AX57 Go (WISP): `VPN > VPN Client > WireGuard` -> upload `.conf`.

Verify:

```sh
ping 10.8.0.1              # VPN server, tunnel UP
docker exec wgeasy wg show   # handshakes = active peers (or UI status dot)
curl ifconfig.me          # public IP = Homelab uplink
```

Open Chrome: `https://192.168.1.150:3001` (HTTPS required, accept self-signed). No login by default.

> Changing client DNS later is per-client in the UI (Edit Client -> DNS).
> Re-download the `.conf`/QR after editing.

Example peer config (keys redacted):

```ini
[Interface]
Address = 10.8.0.2/32
DNS = 10.14.0.2

[Peer]
Endpoint = 192.168.1.150:51821
AllowedIPs = 0.0.0.0/0
```

## 6. Add / revoke peers

All in the UI, no `.env` involved:

- Add: New Client -> name it (`phone2`, `asus`, ...) -> QR/`.conf` to the device.
- Suspend: toggle off (keeps keys, blocks tunnel). Useful for lost devices.
- Revoke/rotate: Delete -> New Client with the same name (fresh keys).
- Expiry: set per client if temporary.

> One peer per device. Two devices sharing a `.conf` (same `10.8.0.x`)
> steal each other's handshake and flap.

- Back up `./wgeasy-data/` (server keys + client registry). Losing it means
  recreating every peer.

## 7. Go external (DDNS)

Internal test uses `WG_HOST=192.168.1.150` in the UI wizard. For outside access:

1. In the UI (Interface settings): `WG_HOST=vpn.example.com` (or current DDNS).
   No recreate needed.
2. Existing clients keep keys but their `Endpoint` still points to the old IP.
   Either re-download their `.conf`/QR or edit the `Endpoint` line manually.
3. Forward `51821/udp` on router to `192.168.1.150:51821`. Never forward the UI port.
4. Test from mobile data (WiFi off).

> All web UIs use LAN URLs (`192.168.1.150`), so over VPN (full tunnel) they
> work as if at home. Do NOT expose them on the router.

## 8. Manage

```sh
cd ~/vpn-docker
docker compose ps
docker compose up -d                       # all (DNS first if fresh)
docker compose up -d wgeasy chrome      # subset
docker compose restart wgeasy
```

Service shortcuts:

| App | URL | Notes |
|---|---|---|
| Homer (menu) | `http://192.168.1.150/` | start here, no port. Edit cards in `homer-assets/config.yml`, scp it over, refresh browser (bind mount, no restart) |
| Pi-hole | `http://192.168.1.150:8081` | `PIHOLE_PASSWORD` |
| Portainer | `https://192.168.1.150:9443` | create admin at first visit |
| Chrome | `https://192.168.1.150:3001` | accept self-signed |
| WeTTY | `https://192.168.1.150:7681` | user `vpnuser` + host password |
| Status (Kuma) | `http://192.168.1.150:3002` | add monitors for each `:port` |
| Backups (Backrest) | `http://192.168.1.150:9898` | create repo in `/repos`, add `/backup/stack` path |
| Files | `http://192.168.1.150:8082` | serves `./filebrowser-srv/`, default admin/admin |
| WireGuard UI | `http://192.168.1.150:8080` | LAN-only, password. New clients, QR, Tx/Rx, on/off |

```sh
docker logs wgeasy --tail 100
docker exec wgeasy wg show      # handshakes = active peers (or UI status)
docker compose stop chrome                  # save RAM on small boards
docker compose up -d chrome
```

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `failed to bind host port 0.0.0.0:53` | Ubuntu `systemd-resolved` stub holds 53 | §1: `DNSStubListener=no`, restart resolved |
| No handshake | wrong `Endpoint`/port, firewall | re-download `.conf` from UI (check `:51821`), `ss -tulpn`, open UDP on router for external |
| DNS fails inside VPN | pihole down | `docker ps` pihole healthy, `getent hosts` test §2, fallback `PEERDNS=192.168.1.1` |
| Recreate conflict / stuck removal | slow daemon under load | wait, `docker ps -a`, remove stale `Created` containers, retry |
| ssh timeouts | small board under pull/gravity load | short commands, detached `nohup ... &`, retry |
| Big pulls stall foreground ssh | multi-minute layers | detached pull, poll logs in `/tmp` |
| Browser `ERR_SSL_PROTOCOL_ERROR` on WeTTY | browser forces https on http URL | WeTTY serves TLS now: use `https://` URL |
| Can't open web UI from LAN | by design (VPN-only firewall) | connect VPN first, or check `iptables -L DOCKER-USER` |
| Chrome demands HTTPS | KasmVNC requires TLS | use port `3001` URL, accept self-signed |

## 10. Security

- Web UIs are VPN-only: host firewall (`DOCKER-USER`, `~/vpn-docker/firewall.sh`, cron `@reboot`)
  allows app ports (80,3000,3001,3002,7681,8000,8080,8082,8443,9443,9898 TCP + 53) solely from
  the VPN subnet `10.8.0.0/24` and localhost. LAN devices get timeouts by design.
  Only WireGuard `51821/udp` is reachable from anywhere (handshake needs it).
  SSH `:22` untouched (host INPUT, LAN login still works for recovery).

- Treat every client `.conf`/QR as a password. It holds the `PrivateKey`. Do not commit to git.
- `.env`, `peers/`, `*-config/`, `wetty-ssl/`, `*.png` are gitignored. Never commit secrets.
- Create Portainer admin immediately; fresh install is open-registration.
- WeTTY = full host shell in browser. VPN-only (+ localhost), strong host password.
- Chrome has no auth. VPN-only (+ localhost).
- Full tunnel (`0.0.0.0/0`) routes all peer traffic via Homelab. Use split tunnel per client in the UI (`AllowedIPs = 10.8.0.0/24, 192.168.1.0/24`) if full exit not wanted.
- Back up: `./wgeasy-data/` (server keys + client registry), `./pihole-etc/` (lists+stats), `./portainer-data/`, `.env`.
