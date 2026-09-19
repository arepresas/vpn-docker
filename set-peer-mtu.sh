#!/bin/bash
# Normaliza MTU y persistent_keepalive de los peers WireGuard de wg-easy.
#
# Por que existe: en redes moviles (4G/5G) el camino real suele soportar menos
# de 1420 bytes, que es el MTU que wg-easy anuncia por defecto. Los paquetes
# grandes se pierden en silencio (agujero negro de MTU): el handshake TCP
# funciona y las paginas pequenas cargan, pero las grandes se quedan colgadas.
# WireGuard usa MTU 1420 = 1500 - 80 bytes de cabeceras (IPv4 20 + UDP 8 +
# WireGuard 32 + TCP 20). Un MTU de 1280 deja margen comodo para 4G/5G.
#
# persistent_keepalive=25 mantiene viva la sesion bajo CGNAT de operadora: sin
# el, la operadora cierra la traduccion de puertos y el tunel cae solo.
#
# Hace dos cosas, y las dos son necesarias:
#
#   1. Defaults (lo importante). user_configs_table.default_mtu y
#      default_persistent_keepalive son los valores que wg-easy copia a cada
#      peer NUEVO que se crea desde la UI. Sin tocarlos, cualquier peer creado
#      despues nace con 1420/0 y reproduce el bug. Es la parte que evita tener
#      que repetir esto en cada maquina nueva.
#   2. Red de seguridad. Corrige los peers ya existentes (creados antes de
#      esto, o desde la API saltandose la UI). Los peers deshabilitados se
#      dejan como estan.
#
# wg-easy v15 no expone variable de entorno para el MTU (no existe INIT_MTU;
# si INIT_HOST, INIT_PORT, INIT_DNS, INIT_ALLOWED_IPS, INIT_IPV4_CIDR) ni lo
# expone el compose, asi que la unica via es editar su base de datos SQLite.
# Por eso este script. wg-easy relee la DB al arrancar, de ahi el reinicio.
#
# Idempotente: se puede ejecutar en cada arranque sin efecto acumulativo.
# No toca claves, IPs ni nombres de peers, solo dos campos de tunel.
#
# Uso:
#   ./set-peer-mtu.sh                 # todos los peers, MTU 1280, keepalive 25
#   ./set-peer-mtu.sh 1400            # otro MTU para todos
#   ./set-peer-mtu.sh 1280 25 Mobile  # otro MTU/keepalive, solo un peer
set -euo pipefail

CONTAINER="${WGEASY_CONTAINER:-wgeasy}"
DB="/tmp/wg-easy-peer-tune.db"

MTU=1280
KEEPALIVE=25

# Los peers a tocar se nombran como argumentos a partir del 3º; sin ellos, todos.
if [ "$#" -gt 2 ]; then
  MTU="$1"
  KEEPALIVE="$2"
  shift 2
elif [ "$#" -gt 0 ]; then
  MTU="$1"
  if [ "$#" -gt 1 ]; then KEEPALIVE="$2"; fi
  shift "$#"
fi
PEERS=("$@")

log() { printf '[set-peer-mtu] %s\n' "$*"; }
die() { printf '[set-peer-mtu] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker no encontrado"
command -v python3 >/dev/null || die "python3 no encontrado en el host"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  # En un arranque en frio el contenedor aun no existe: no es un error.
  log "contenedor '$CONTAINER' no esta corriendo; nada que hacer"
  exit 0
fi

# Se trabaja sobre una copia: si algo falla a mitad, la DB real sigue intacta.
# La copia contiene claves privadas de WireGuard, asi que se destruye siempre,
# tanto si el script termina bien como si aborta por error.
docker cp "$CONTAINER:/etc/wireguard/wg-easy.db" "$DB" >/dev/null 2>&1 \
  || die "no se pudo copiar la base de datos de $CONTAINER"
trap 'rm -f "$DB"' EXIT

peers_json="[]"
if [ "${#PEERS[@]}" -gt 0 ]; then
  peers_json="$(printf '%s\n' "${PEERS[@]}" \
    | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
fi

# El script de python imprime "cambios=N" para decidir si hay que reiniciar.
output="$(python3 - "$DB" "$MTU" "$KEEPALIVE" "$peers_json" <<'PY'
import json
import sqlite3
import sys

db_path, mtu, keepalive = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
raw = json.loads(sys.argv[4])

con = sqlite3.connect(db_path)
cur = con.cursor()

# Un fichero ilegible hace que sqlite lance la excepcion antes de devolver
# estado, asi que se captura para dar un mensaje y no un traceback.
try:
    status = cur.execute("pragma integrity_check").fetchone()[0]
except sqlite3.DatabaseError as exc:
    sys.exit(f"base de datos ilegible ({exc}); no se toca")
if status != "ok":
    sys.exit(f"base de datos corrupta ({status}); no se toca")

changes = 0

# --- 1. Defaults para los peers que se creen en el futuro -------------------
tiene_users = cur.execute(
    "select count(*) from sqlite_master where type='table' and name='user_configs_table'"
).fetchone()[0]

if tiene_users:
    for cfg_id, cur_mtu, cur_ka in cur.execute(
        "select id, default_mtu, default_persistent_keepalive from user_configs_table"
    ).fetchall():
        if (cur_mtu, cur_ka) == (mtu, keepalive):
            continue
        cur.execute(
            "update user_configs_table set default_mtu=?, default_persistent_keepalive=? where id=?",
            (mtu, keepalive, cfg_id),
        )
        print(f"defaults {cfg_id}: mtu {cur_mtu}->{mtu}, keepalive {cur_ka}->{keepalive}")
        changes += 1
else:
    print("sin user_configs_table; no se ajustan los defaults")

# --- 2. Red de seguridad sobre los peers ya existentes ----------------------
rows = cur.execute(
    "select id, name, ipv4_address, mtu, persistent_keepalive, enabled from clients_table"
).fetchall()

if rows and raw:
    unknown = [n for n in raw if n not in {r[1] for r in rows}]
    if unknown:
        sys.exit(f"peer(s) no encontrado(s): {', '.join(unknown)}")

for cid, name, ip, cur_mtu, cur_ka, enabled in rows:
    if raw and name not in raw:
        continue
    # Un peer deshabilitado se deja como esta: reactivarlo mas tarde con un
    # MTU forzado cambiaria su configuracion sin avisar.
    new_mtu = mtu if enabled else cur_mtu
    new_ka = keepalive if enabled else cur_ka
    if (new_mtu, new_ka) == (cur_mtu, cur_ka):
        continue
    cur.execute(
        "update clients_table set mtu=?, persistent_keepalive=? where id=?",
        (new_mtu, new_ka, cid),
    )
    print(f"actualizado {name} ({ip}): mtu {cur_mtu}->{new_mtu}, keepalive {cur_ka}->{new_ka}")
    changes += 1

if not changes:
    print("todo estaba ya correcto")
    print("cambios=0")
    sys.exit(0)

con.commit()
con.close()
print(f"cambios={changes}")
PY
)" || die "fallo al editar la base de datos"

changes=0
while IFS= read -r line; do
  case "$line" in
    cambios=*) changes="${line#cambios=}" ;;
    '') ;;
    *) log "$line" ;;
  esac
done <<EOF
$output
EOF

if [ "$changes" -eq 0 ]; then
  # La copia contiene claves privadas: se borra siempre, tenga cambios o no.
  rm -f "$DB"
  exit 0
fi

# wg-easy solo relee la DB al arrancar, asi que hay que devolvérsela y
# reiniciarlo para que el cambio surta efecto.
docker cp "$DB" "$CONTAINER:/etc/wireguard/wg-easy.db" >/dev/null 2>&1 \
  || die "no se pudo escribir la base de datos de vuelta en $CONTAINER"
# docker cp conserva el propietario del origen, que aqui es el usuario que
# ejecuta el script; la DB debe seguir siendo root:root como el resto.
docker exec -u 0 "$CONTAINER" chown root:root /etc/wireguard/wg-easy.db >/dev/null 2>&1 || true

# La copia contiene claves privadas: se borra siempre.
rm -f "$DB"

if [ "${SET_PEER_MTU_NO_RESTART:-0}" = "1" ]; then
  log "cambios guardados (sin reinicio por SET_PEER_MTU_NO_RESTART=1)"
  exit 0
fi

if docker restart "$CONTAINER" >/dev/null 2>&1; then
  log "wgeasy reiniciado para cargar la configuracion"
else
  die "se aplicaron cambios pero no se pudo reiniciar $CONTAINER; ejecuta: docker restart $CONTAINER"
fi
