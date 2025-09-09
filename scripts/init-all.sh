#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && export $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | xargs)

TOKEN_LABEL="${SOFTHSM_TOKEN_LABEL:-DOLICORP}"
USER_PIN="${SOFTHSM_USER_PIN:-1234}"
SO_PIN="${SOFTHSM_SO_PIN:-0000}"
KEY_PREFIX="${PKCS11_KEY_LABEL_PREFIX:-svc}"
SOFTHSM_ENV=(-e SOFTHSM2_CONF=/etc/softhsm2.conf)

log(){ printf '%s %s\n' "[$(date +%H:%M:%S)]" "$*"; }

# 1) Base up (réseau + conteneur softhsm build local)
docker compose -f docker-compose.base.yml up -d --build

# 2) Conf SoftHSM + réinit store (zéro état résiduel)
log "Préparation du store SoftHSM…"
docker exec "${SOFTHSM_ENV[@]}" softhsm bash -lc 'cat >/etc/softhsm2.conf <<EOF
directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend = file
slots.removable = true
EOF'
docker exec "${SOFTHSM_ENV[@]}" softhsm bash -lc 'mkdir -p /var/lib/softhsm/tokens && rm -rf /var/lib/softhsm/tokens/*'

# 3) Créer le token NEUF en posant SO PIN + USER PIN directement (pas d'init-pin ensuite)
log "Initialisation du token '${TOKEN_LABEL}' (SO PIN + USER PIN)…"
docker exec "${SOFTHSM_ENV[@] }" softhsm softhsm2-util --init-token --free  --label "${TOKEN_LABEL}" --so-pin "${SO_PIN}" --pin "${USER_PIN}"

# 3.1) Récupérer le slot du token par label (robuste Label:/Token label:)
get_slot() {
  docker exec "${SOFTHSM_ENV[@]}" softhsm bash -lc '
set -e
out="$(softhsm2-util --show-slots)"
# 1) Essai par label exact (Label: ou Token label:)
slot="$(printf "%s\n" "$out" | awk -v LBL="'"${TOKEN_LABEL}"'" "
  /^Slot /{cur=\$2}
  /(^|[[:space:]])(Label:|Token label:)[[:space:]]*$/ { next }  # lignes vides de label
  /Label:[[:space:]]*.*|Token label:[[:space:]]*.*/ {
     line=\$0
     gsub(/^ +| +$/,\"\", line)
     if (index(line, LBL)>0) { slot=cur }
  }
  END{ print slot }
")"

# 2) Secours : prendre le slot où User PIN init.: yes
if [ -z "$slot" ]; then
  slot="$(printf "%s\n" "$out" | awk "
    /^Slot /{cur=\$2}
    /User PIN init\\.: *yes/ { slot=cur }
    END{ print slot }
  ")"
fi

echo -n "$slot"
'
}

SLOT="$(get_slot)"
if [ -z "${SLOT}" ]; then
  echo "❌ Impossible de trouver le slot du token '${TOKEN_LABEL}' (format différent). Dump:"
  docker exec "${SOFTHSM_ENV[@]}" softhsm softhsm2-util --show-slots || true
  exit 1
fi
log "Token '${TOKEN_LABEL}' prêt sur slot ${SLOT}"

# 4) Générer 1 paire RSA par service pkcs11 (login user sur ce slot)
i=1
for SVC in pg mysql mariadb mongo; do
  OBJ="${KEY_PREFIX}-${SVC}"
  ID_HEX=$(printf "%02x" "$i")  # 01, 02, 03, 04…

  log "Génération clé RSA persistante pour ${OBJ} (ID=${ID_HEX})…"

  docker exec "${SOFTHSM_ENV[@]}" softhsm bash -lc \
    "set -euo pipefail; pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
      --slot '${SLOT}' --login --pin '${USER_PIN}' --session-rw \
      --keypairgen --key-type rsa:2048 \
      --label '${OBJ}' --id '${ID_HEX}' \
      --private"

  i=$((i+1))
done

# 5) Sanity check : lister les objets (on doit voir au moins 4 paires)
log "Vérification des objets dans le token…"
docker exec "${SOFTHSM_ENV[@]}" softhsm bash -lc \
  "pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
     --slot '${SLOT}' --login --pin '${USER_PIN}' \
     --list-objects --type privkey -v | sed -n '1,200p'"

echo
echo "✅ SoftHSM prêt (token='${TOKEN_LABEL}', slot=${SLOT}). Lance les moteurs :"
echo "  docker compose -f docker-compose.base.yml -f docker-compose.postgres.yml up -d --build && docker logs -f seeder_pg"
echo "  docker compose -f docker-compose.base.yml -f docker-compose.mysql.yml    up -d --build && docker logs -f seeder_mysql"
echo "  docker compose -f docker-compose.base.yml -f docker-compose.mariadb.yml  up -d --build && docker logs -f seeder_mariadb"
echo "  docker compose -f docker-compose.base.yml -f docker-compose.mongo.yml    up -d --build && docker logs -f seeder_mongo"
