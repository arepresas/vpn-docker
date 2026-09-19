#!/bin/bash
# Pi-hole blocklists + allowlist bootstrap - run AFTER `docker compose up -d pihole`.
# Idempotent: re-running only adds missing entries, never duplicates.
# Usage: ./pihole-lists.sh [--update-now] [--with-threat] [--with-extra]
#   --update-now   run `pihole -g` (gravity rebuild, minutes). Without flag only stages.
#   --with-threat  add small high-value threat feeds (URLHaus, ThreatFox, Hagezi spam-TLDs).
#                  Skipped by default: keeps RAM low on small boards (Orange Pi).
#   --with-extra   add 5 low-risk extra lists (fakenews, SmartTV, RPiList x2, uBlock badware).
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${PIHOLE_CONTAINER:-pihole}"
GRAVITY_DB="$COMPOSE_DIR/pihole-etc/gravity.db"

# ---- Tier 1 BASE (balanced, low false positives). ~500-600k domains ----
# NOTE: Hagezi for Pi-hole uses the *adblock* format (not wildcard/*).
BASE_LISTS=(
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts|StevenBlack unified"
  "https://small.oisd.nl|OISD Small"
  "https://big.oisd.nl|OISD Big"
  "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt|Hagezi Multi Pro (adblock)"
  "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt|AdGuard DNS filter"
)

# ---- Tier 2 THREAT (opt-in via --with-threat). Small, focused ----
THREAT_LISTS=(
  "https://urlhaus.abuse.ch/downloads/hostfile/|URLHaus malware"
  "https://threatfox.abuse.ch/downloads/hostfile/|ThreatFox C2"
  "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/spam-tlds.txt|Hagezi most-abused-TLDs"
  # Heavy hitters, NOT enabled by default (RAM + FP risk on small boards):
  # "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.txt|Hagezi TIF full (~2M, needs >=2GB)"
  # "https://raw.githubusercontent.com/Tempest-Solutions-Company/pihole_blocklists/main/phishing.txt|Tempest phishing (~900k)"
  # "https://raw.githubusercontent.com/Tempest-Solutions-Company/pihole_blocklists/main/malware.txt|Tempest malware"
)

# ---- Tier 3 EXTRA (opt-in via --with-extra). Low FP, verified Pi-hole format ----
EXTRA_LISTS=(
  "https://raw.githubusercontent.com/StevenBlack/hosts/master/extensions/fakenews/hosts|StevenBlack fakenews"
  "https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt|SmartTV Perflyst+Dandelion"
  "https://raw.githubusercontent.com/RPiList/specials/master/Blocklisten/malware|RPiList malware"
  "https://raw.githubusercontent.com/RPiList/specials/master/Blocklisten/easylist|RPiList EasyList extended"
  "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt|uBlock badware risks"
)

# ---- Allowlist (exact, type=allow). Prevents breakage of updates, auth, media ----
# Sources: GoodnessJSON/anudeepND community whitelist, Pi-hole discourse,
# O365 whitelist (never block login.microsoftonline.com), Spotify/Xbox/Apple notes.
ALLOW_DOMAINS=(
  "www.msftncsi.com|Windows connectivity check"
  "ctldl.windowsupdate.com|Windows Update"
  "download.windowsupdate.com|Windows Update"
  "login.microsoftonline.com|M365 auth - NEVER block"
  "outlook.office365.com|M365 Outlook"
  "teams.microsoft.com|M365 Teams"
  "spclient.wg.spotify.com|Spotify client (breaks without)"
  "apresolve.spotify.com|Spotify resolve"
  "api-tv.spotify.com|Spotify TV"
  "open.spotify.com|Spotify web"
  "mask.icloud.com|Apple Private Relay - blocking breaks iCloud"
  "mask-h2.icloud.com|Apple Private Relay"
  "connectivitycheck.gstatic.com|Android captive/connectivity"
  "play.googleapis.com|Google Play"
  "amazon.com|avoid overblock basics"
  "primevideo.com|Prime Video"
  "netflix.com|Netflix"
  "disneyplus.com|Disney+"
  "xboxlive.com|Xbox Live root"
  "attestation.xboxlive.com|Xbox attestation"
  "title.auth.xboxlive.com|Xbox auth"
  "banking|placeholder-removed-below"
)

UPDATE_NOW=0; WITH_THREAT=0; WITH_EXTRA=0
for a in "$@"; do
  [[ "$a" == "--update-now" ]] && UPDATE_NOW=1
  [[ "$a" == "--with-threat" ]] && WITH_THREAT=1
  [[ "$a" == "--with-extra" ]] && WITH_EXTRA=1
done
# drop placeholder line (keeps array syntax obvious when editing)
ALLOW_DOMAINS=("${ALLOW_DOMAINS[@]/banking|placeholder-removed-below}")

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need docker; need python3

if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Container $CONTAINER not found. Run first:" >&2
  echo "  docker compose up -d pihole" >&2
  exit 1
fi

WAS_RUNNING=0
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" && WAS_RUNNING=1
[[ $WAS_RUNNING == 1 ]] && { echo "Stopping $CONTAINER for safe DB write..."; docker stop "$CONTAINER" >/dev/null; }

if [[ ! -f "$GRAVITY_DB" ]]; then
  echo "gravity.db not found at $GRAVITY_DB. Start pihole once first." >&2
  [[ $WAS_RUNNING == 1 ]] && docker start "$CONTAINER" >/dev/null
  exit 1
fi
cp -n "$GRAVITY_DB" "$GRAVITY_DB.bak" 2>/dev/null || true

LISTS=("${BASE_LISTS[@]}")
[[ $WITH_THREAT == 1 ]] && LISTS+=("${THREAT_LISTS[@]}")
[[ $WITH_EXTRA == 1 ]] && LISTS+=("${EXTRA_LISTS[@]}")
LIST_DATA=$(printf '%s\n' "${LISTS[@]}")
ALLOW_DATA=$(printf '%s\n' "${ALLOW_DOMAINS[@]}")

read -r ADDED ALLOWED < <(python3 - "$GRAVITY_DB" "$LIST_DATA" "$ALLOW_DATA" <<'PY'
import sqlite3, sys
db, lists, allows = sys.argv[1], sys.argv[2], sys.argv[3]
con = sqlite3.connect(db); cur = con.cursor()
added = 0
for line in lists.strip().splitlines():
    url, _, comment = line.partition("|")
    cur.execute("INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES (?, 1, ?)",
                (url.strip(), comment.strip()))
    added += cur.rowcount
allowed = 0
for line in allows.strip().splitlines():
    dom, _, comment = line.partition("|")
    dom = dom.strip()
    if not dom:
        continue
    # domainlist.type: 0 = exact allow, 1 = exact deny, 2/3 = regex allow/deny.
    # A trigger auto-adds each row to domainlist_by_group (Default group).
    cur.execute("INSERT OR IGNORE INTO domainlist (type, domain, enabled, comment) VALUES (0, ?, 1, ?)",
                (dom, comment.strip()))
    allowed += cur.rowcount
con.commit()
print(f"{added} {allowed}")
PY
)
echo "New adlists: $ADDED | new allowlist domains: $ALLOWED (0 = already present)"
docker exec "$CONTAINER" true 2>/dev/null || docker start "$CONTAINER" >/dev/null

echo "Waiting for Pi-hole FTL..."
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pihole status >/dev/null 2>&1 && break
  sleep 2
done

if [[ $UPDATE_NOW == 1 ]]; then
  echo "Rebuilding gravity (minutes, log /tmp/gravity.log)..."
  # shellcheck disable=SC2024
  nohup docker exec "$CONTAINER" pihole -g > /tmp/gravity.log 2>&1 &
  echo "Follow: tail -f /tmp/gravity.log"
else
  echo "Staged. Apply with: ./pihole-lists.sh --update-now (add --with-threat / --with-extra for more feeds)"
fi
echo "Verify: docker exec chrome getent hosts doubleclick.net (expect 0.0.0.0) | google.com (resolves)"
