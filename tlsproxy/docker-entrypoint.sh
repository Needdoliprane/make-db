#!/usr/bin/env sh
set -eu

: "${SERVICE_NAME:=pg_pkcs11}"
: "${ACCEPT_PORT:=35432}"
: "${CONNECT_HOST:=pg-pkcs11}"
: "${CONNECT_PORT:=5432}"
: "${ENABLE_PKCS11:=1}"

: "${SOFTHSM_TOKEN_LABEL:=DOLICORP}"
: "${SOFTHSM_USER_PIN:=1234}"
: "${PKCS11_OBJECT_LABEL:=svc-pg}"
: "${PKCS11_FORCE_URI:=}"

ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
export OPENSSL_CONF="/etc/ssl/openssl-pkcs11.cnf"
export SOFTHSM2_CONF="/etc/softhsm2.conf"
export OPENSSL_ENGINES="/usr/lib/${ARCH}/engines-3"
export OPENSSL_MODULES="/usr/lib/${ARCH}/ossl-modules"
PKCS11_MODULE_PATH="/usr/lib/softhsm/libsofthsm2.so"

log() { printf '%s\n' "$*"; }

has_obj() {
  # $1: type (privkey|cert)
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
    --token-label "${SOFTHSM_TOKEN_LABEL}" --login --pin "${SOFTHSM_USER_PIN}" \
    --list-objects --type "$1" 2>/dev/null | grep -q "label:[[:space:]]*${PKCS11_OBJECT_LABEL}"
}

wait_for_hsm() {
  t=0; max="${HSM_WAIT_SECONDS:-25}"
  while [ $t -lt $max ]; do
    if has_obj privkey; then
      # If cert missing, still give a few seconds more (import may race)
      if has_obj cert; then return 0; fi
    fi
    sleep 1; t=$((t+1))
  done
  return 1
}

# Build stunnel.conf from template
export SERVICE_NAME ACCEPT_PORT CONNECT_HOST CONNECT_PORT
envsubst < /stunnel.conf.template > /etc/stunnel/stunnel.conf

if [ "${ENABLE_PKCS11}" = "1" ]; then
  # Global engine
  sed -i "s|@ENGINE_GLOBAL@|engine = pkcs11\nengineCtrl = MODULE_PATH:${PKCS11_MODULE_PATH}\nengineCtrl = PIN:${SOFTHSM_USER_PIN}|" /etc/stunnel/stunnel.conf

  USE_ENGINE_FOR_CERT=0
  if [ -n "${PKCS11_FORCE_URI}" ]; then
    KEY_URI="${PKCS11_FORCE_URI}"
    CERT_URI="${PKCS11_FORCE_URI%type=*}type=cert"
    USE_ENGINE_FOR_CERT=1
    log "[info] FORCE_URI activé"
  else
    if wait_for_hsm; then
      KEY_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${PKCS11_OBJECT_LABEL};type=private"
      CERT_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${PKCS11_OBJECT_LABEL};type=cert"
      USE_ENGINE_FOR_CERT=1
      log "[info] HSM prêt (label=${PKCS11_OBJECT_LABEL})"
    else
      # Fallback propre: on démarre quand même en FS (le proxy vit, ton seeder avance)
      KEY_URI="/certs/server/${SERVICE_NAME}/server.key"
      CERT_URI="/certs/server/${SERVICE_NAME}/server.crt"
      USE_ENGINE_FOR_CERT=0
      log "[warn] HSM indisponible après attente -> fallback FS (cert/key fichiers)"
    fi
  fi

  if [ "${USE_ENGINE_FOR_CERT}" = "1" ]; then
    sed -i "s|@ENGINE_SERVICE@|engineId = pkcs11|" /etc/stunnel/stunnel.conf
    sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|" /etc/stunnel/stunnel.conf
    sed -i "s|@KEY_LINE@|key  = ${KEY_URI}|"   /etc/stunnel/stunnel.conf
  else
    sed -i "s|@ENGINE_SERVICE@||" /etc/stunnel/stunnel.conf
    sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|" /etc/stunnel/stunnel.conf
    sed -i "s|@KEY_LINE@|key  = ${KEY_URI}|"   /etc/stunnel/stunnel.conf
  fi
else
  sed -i "s|@ENGINE_GLOBAL@||" /etc/stunnel/stunnel.conf
  sed -i "s|@ENGINE_SERVICE@||" /etc/stunnel/stunnel.conf
  sed -i "s|@CERT_LINE@|cert = /certs/server/${SERVICE_NAME}/server.crt|" /etc/stunnel/stunnel.conf
  sed -i "s|@KEY_LINE@|key  = /certs/server/${SERVICE_NAME}/server.key|"   /etc/stunnel/stunnel.conf
fi

log "----- /etc/stunnel/stunnel.conf -----"
sed -n '1,200p' /etc/stunnel/stunnel.conf || true
log "-------------------------------------"

exec /usr/bin/stunnel /etc/stunnel/stunnel.conf

# #!/usr/bin/env sh
# set -eu

# # ========= Paramètres =========
# : "${SERVICE_NAME:=pg_pkcs11}"
# : "${ACCEPT_PORT:=35432}"
# : "${CONNECT_HOST:=pg-pkcs11}"
# : "${CONNECT_PORT:=5432}"
# : "${ENABLE_PKCS11:=1}"

# # SoftHSM / PKCS#11
# : "${SOFTHSM_TOKEN_LABEL:=DOLICORP}"
# : "${SOFTHSM_USER_PIN:=1234}"
# : "${PKCS11_OBJECT_LABEL:=svc-pg}"   # label préféré
# : "${PKCS11_FORCE_URI:=}"            # pkcs11:... (debug/override)

# # ========= Chemins multi-arch =========
# ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
# export OPENSSL_CONF="/etc/ssl/openssl-pkcs11.cnf"
# export SOFTHSM2_CONF="/etc/softhsm2.conf"
# export OPENSSL_ENGINES="/usr/lib/${ARCH}/engines-3"
# export OPENSSL_MODULES="/usr/lib/${ARCH}/ossl-modules"

# PKCS11_ENGINE_PATH="${OPENSSL_ENGINES}/pkcs11.so"
# PKCS11_MODULE_PATH="/usr/lib/softhsm/libsofthsm2.so"

# # ========= Conf SoftHSM par défaut (si absente) =========
# if [ ! -f "${SOFTHSM2_CONF}" ]; then
#   cat > "${SOFTHSM2_CONF}" <<EOF
# directories.tokendir = /var/lib/softhsm/tokens
# objectstore.backend  = file
# slots.removable      = true
# EOF
# fi

# # ========= Helpers =========
# get_slot_id_for_token() {
#   softhsm2-util --show-slots 2>/dev/null | awk -v lbl="$SOFTHSM_TOKEN_LABEL" '
#     $1=="Slot" && $2~/^[0-9]+$/ { sid=$2; next }
#     $1=="Label:" || ($1=="Token" && $2=="label:") {
#       l=$0
#       sub(/^[^:]*:[[:space:]]*/, "", l)
#       gsub(/[[:space:]]+$/, "", l)
#       if (l==lbl) { print sid; exit }
#     }
#   '
# }

# list_privkeys_label_id() {
#   [ -n "${SLOT_ID:-}" ] || SLOT_ID="$(get_slot_id_for_token || true)"
#   [ -n "${SLOT_ID:-}" ] || { echo "[error] SLOT_ID introuvable" >&2; return 1; }

#   pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
#     --slot "${SLOT_ID}" --login --pin "${SOFTHSM_USER_PIN}" \
#     --list-objects --type privkey 2>/dev/null \
#   | awk '
#       BEGIN { lab=""; haveLab=0 }
#       /^[[:space:]]*[Ll]abel:[[:space:]]*/ { lab=$0; sub(/^[^:]*:[[:space:]]*/,"",lab); gsub(/[[:space:]]+$/, "", lab); haveLab=1; next }
#       /^[[:space:]]*ID:[[:space:]]*/ {
#         id=$0; sub(/^[^:]*:[[:space:]]*/,"",id); gsub(/[:[:space:]]/,"",id); id=tolower(id);
#         if (haveLab && lab!="") { print lab "|" id; haveLab=0; lab=""; id="" }
#       }
#     '
# }

# has_cert_in_hsm_by_id() {
#   key_id_hex="$1" # ex: 01
#   [ -n "${SLOT_ID:-}" ] || SLOT_ID="$(get_slot_id_for_token || true)"
#   [ -n "${SLOT_ID:-}" ] || return 1
#   pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
#     --slot "${SLOT_ID}" --login --pin "${SOFTHSM_USER_PIN}" \
#     --list-objects --type cert 2>/dev/null \
#   | awk -v want="$(echo "$key_id_hex" | tr '[:upper:]' '[:lower:]')" '
#       /^[[:space:]]*ID:[[:space:]]*/ {
#         id=$0; sub(/^[^:]*:[[:space:]]*/,"",id); gsub(/[:[:space:]]/,"",id); id=tolower(id);
#         if (id==want) { found=1 }
#       }
#       END { exit (found?0:1) }
#     '
# }

# pick_best_key() {
#   want="$1" ; first=""
#   while IFS= read -r line; do
#     [ -z "$first" ] && first="$line"
#     lab="${line%%|*}"
#     if [ "$lab" = "$want" ]; then echo "$line"; return 0; fi
#   done
#   [ -n "$first" ] && { echo "$first"; return 0; }
#   return 1
# }

# # ========= DEBUG =========
# echo "[debug] ARCH=${ARCH}"
# echo "[debug] OPENSSL_CONF=${OPENSSL_CONF}"
# echo "[debug] SOFTHSM2_CONF=${SOFTHSM2_CONF}"
# echo "[debug] OPENSSL_ENGINES=${OPENSSL_ENGINES}"
# echo "[debug] OPENSSL_MODULES=${OPENSSL_MODULES}"
# ls -l "${PKCS11_ENGINE_PATH}" || true
# ls -l "${PKCS11_MODULE_PATH}" || true

# echo "[debug] Slots SoftHSM :"
# softhsm2-util --show-slots || true

# SLOT_ID="$(get_slot_id_for_token || true)"
# echo "[debug] SLOT_ID détecté : ${SLOT_ID:-<none>}"

# echo "[debug] Objets privés (label|id) sur token '${SOFTHSM_TOKEN_LABEL}':"
# KEYS_LIST="$(list_privkeys_label_id || true)"
# printf '%s\n' "${KEYS_LIST:-<none>}"

# # ========= Sélection de la clé =========
# if [ "${ENABLE_PKCS11}" = "1" ]; then
#   if [ -n "${PKCS11_FORCE_URI}" ]; then
#     CHOSEN_ID="" ; KEY_URI="${PKCS11_FORCE_URI}"
#   else
#     SEL="$(printf '%s\n' "${KEYS_LIST:-}" | pick_best_key "${PKCS11_OBJECT_LABEL}" || true)"
#     CHOSEN_LABEL="${SEL%%|*}"
#     CHOSEN_ID="${SEL##*|}"
#     [ -n "${CHOSEN_ID:-}" ] || { echo "[error] Aucune clé privée trouvée sur token '${SOFTHSM_TOKEN_LABEL}'" >&2; exit 1; }
#     KEY_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};id=${CHOSEN_ID};type=private"
#   fi
# else
#   CHOSEN_ID="" ; KEY_URI="/certs/server/${SERVICE_NAME}/server.key"
# fi
# echo "[debug] CHOSEN_LABEL='${CHOSEN_LABEL:-}'  CHOSEN_ID='${CHOSEN_ID:-}'"
# echo "[debug] KEY_URI -> ${KEY_URI}"

# # ========= Cert: préférence HSM (même id) sinon FS =========
# USE_ENGINE_FOR_CERT=0
# if [ -n "${CHOSEN_ID:-}" ] && has_cert_in_hsm_by_id "${CHOSEN_ID}"; then
#   CERT_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};id=${CHOSEN_ID};type=cert"
#   USE_ENGINE_FOR_CERT=1
#   echo "[info] Cert trouvé dans le HSM (id=${CHOSEN_ID})"
# else
#   # fallback FS
#   CERT_URI="/certs/server/${SERVICE_NAME}/server.crt"
#   echo "[warn] Cert ${SERVICE_NAME} absent du HSM -> fallback filesystem"
# fi

# # ========= Construire stunnel.conf =========
# export SERVICE_NAME ACCEPT_PORT CONNECT_HOST CONNECT_PORT
# envsubst < /stunnel.conf.template > /etc/stunnel/stunnel.conf

# # Injecter dynamiquement lignes engine / cert / key
# if [ "${ENABLE_PKCS11}" = "1" ]; then
#   # engine global (charge pkcs11 + PIN)
#   sed -i "s|@ENGINE_GLOBAL@|engine = pkcs11\nengineCtrl = MODULE_PATH:${PKCS11_MODULE_PATH}\nengineCtrl = PIN:${SOFTHSM_USER_PIN}|" /etc/stunnel/stunnel.conf
#   if [ "${USE_ENGINE_FOR_CERT}" = "1" ]; then
#     # engineId pour charger cert+key depuis HSM
#     sed -i "s|@ENGINE_SERVICE@|engineId = pkcs11|" /etc/stunnel/stunnel.conf
#     sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|" /etc/stunnel/stunnel.conf
#     sed -i "s|@KEY_LINE@|key  = ${KEY_URI}|"   /etc/stunnel/stunnel.conf
#   else
#     # pas d'engineId -> cert/clé sur FS (clé HSM non mixable ici)
#     sed -i "s|@ENGINE_SERVICE@||" /etc/stunnel/stunnel.conf
#     sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|" /etc/stunnel/stunnel.conf
#     sed -i "s|@KEY_LINE@|key  = /certs/server/${SERVICE_NAME}/server.key|" /etc/stunnel/stunnel.conf
#   fi
# else
#   sed -i "s|@ENGINE_GLOBAL@||" /etc/stunnel/stunnel.conf
#   sed -i "s|@ENGINE_SERVICE@||" /etc/stunnel/stunnel.conf
#   sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|" /etc/stunnel/stunnel.conf
#   sed -i "s|@KEY_LINE@|key  = ${KEY_URI}|"   /etc/stunnel/stunnel.conf
# fi

# echo "----- /etc/stunnel/stunnel.conf -----"
# sed -n '1,220p' /etc/stunnel/stunnel.conf
# echo "-------------------------------------"

# echo "[debug] openssl engine -t -c pkcs11"
# openssl engine -t -c pkcs11 || true

# exec /usr/bin/stunnel /etc/stunnel/stunnel.conf







#--------- old script

# #!/usr/bin/env sh
# set -eu

# # ---- paramètres ----
# : "${SERVICE_NAME:=pg_pkcs11}"
# : "${ACCEPT_PORT:=35432}"
# : "${CONNECT_HOST:=pg-pkcs11}"
# : "${CONNECT_PORT:=5432}"
# : "${ENABLE_PKCS11:=1}"

# # SoftHSM / PKCS#11
# : "${SOFTHSM_TOKEN_LABEL:=DOLICORP}"
# : "${SOFTHSM_USER_PIN:=1234}"
# : "${PKCS11_OBJECT_LABEL:=svc-pg}"      # label préféré si présent
# : "${PKCS11_FORCE_URI:=}"               # si non vide: bypass auto-découverte

# # ---- chemins runtime multi-arch ----
# ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
# export OPENSSL_CONF="/etc/ssl/openssl-pkcs11.cnf"
# export SOFTHSM2_CONF="/etc/softhsm2.conf"
# export OPENSSL_ENGINES="/usr/lib/${ARCH}/engines-3"
# export OPENSSL_MODULES="/usr/lib/${ARCH}/ossl-modules"

# PKCS11_ENGINE_PATH="${OPENSSL_ENGINES}/pkcs11.so"
# PKCS11_MODULE_PATH="/usr/lib/softhsm/libsofthsm2.so"

# # ---- s’assurer que la conf SoftHSM existe ----
# if [ ! -f "${SOFTHSM2_CONF}" ]; then
#   echo "[fix] Création de ${SOFTHSM2_CONF}"
#   cat > "${SOFTHSM2_CONF}" <<EOF
# directories.tokendir = /var/lib/softhsm/tokens
# objectstore.backend  = file
# slots.removable      = true
# EOF
# fi

# # ---- helpers ----
# get_slot_id_for_token() {
#   softhsm2-util --show-slots 2>/dev/null | awk -v lbl="$SOFTHSM_TOKEN_LABEL" '
#     $1=="Slot" && $2~/^[0-9]+$/ { sid=$2; next }
#     $1=="Label:" || ($1=="Token" && $2=="label:") {
#       l=$0
#       sub(/^[^:]*:[[:space:]]*/, "", l)
#       gsub(/[[:space:]]+$/, "", l)
#       if (l==lbl) { print sid; exit }
#     }
#   '
# }

# # liste "label|idhex" des clés privées
# list_privkeys_label_id() {
#   [ -n "${SLOT_ID:-}" ] || SLOT_ID="$(get_slot_id_for_token || true)"
#   if [ -z "${SLOT_ID:-}" ]; then
#     echo "[error] SLOT_ID manquant pour lister les clés." >&2
#     return 1
#   fi

#   OUT="$(pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
#           --slot "${SLOT_ID}" --login --pin "${SOFTHSM_USER_PIN}" \
#           --list-objects --type privkey 2>&1)" || {
#     echo "[pkcs11-tool] list-objects a échoué" >&2
#     printf '%s\n' "$OUT" >&2
#     return 1
#   }

#   printf '%s\n' "$OUT" | awk '
#     BEGIN { haveLab=0; lab=""; id="" }
#     /^[[:space:]]*[Ll]abel:[[:space:]]*/ {
#       lab=$0; sub(/^[[:space:]]*[Ll]abel:[[:space:]]*/, "", lab);
#       gsub(/[[:space:]]+$/, "", lab); haveLab=1; next
#     }
#     /^[[:space:]]*ID:[[:space:]]*/ {
#       id=$0; sub(/^[[:space:]]*ID:[[:space:]]*/, "", id);
#       gsub(/[:[:space:]]/, "", id); id=tolower(id);
#       if (haveLab && lab!="") { print lab "|" id; haveLab=0; lab=""; id="" }
#     }
#   '
# }

# pick_best_key() {
#   want="$1" ; first=""
#   while IFS= read -r line; do
#     [ -z "$first" ] && first="$line"
#     lab="${line%%|*}"
#     if [ "$lab" = "$want" ]; then echo "$line"; return 0; fi
#   done
#   [ -n "$first" ] && { echo "$first"; return 0; }
#   return 1
# }

# # ---- DEBUG ----
# echo "[debug] ARCH=${ARCH}"
# echo "[debug] OPENSSL_CONF=${OPENSSL_CONF}"
# echo "[debug] SOFTHSM2_CONF=${SOFTHSM2_CONF}"
# echo "[debug] OPENSSL_ENGINES=${OPENSSL_ENGINES}"
# echo "[debug] OPENSSL_MODULES=${OPENSSL_MODULES}"
# ls -l "${PKCS11_ENGINE_PATH}" || true
# ls -l "${PKCS11_MODULE_PATH}" || true

# echo "[debug] Slots SoftHSM :"
# softhsm2-util --show-slots || true

# SLOT_ID="$(get_slot_id_for_token || true)"
# echo "[debug] SLOT_ID détecté : ${SLOT_ID:-<none>}"

# echo "[debug] Objets privés (label|id) sur token '${SOFTHSM_TOKEN_LABEL}':"
# KEYS_LIST="$(list_privkeys_label_id || true)"
# printf '%s\n' "${KEYS_LIST:-<none>}"

# # ---- sélection de la clé / construction URI ----
# if [ "${ENABLE_PKCS11}" = "1" ]; then
#   if [ -n "${PKCS11_FORCE_URI}" ]; then
#     KEY_URI="${PKCS11_FORCE_URI}"
#   else
#     CHOSEN_LABEL="" ; CHOSEN_ID=""
#     if [ -n "${KEYS_LIST:-}" ] && [ "${KEYS_LIST}" != "<none>" ]; then
#       SEL="$(printf '%s\n' "$KEYS_LIST" | pick_best_key "$PKCS11_OBJECT_LABEL" || true)"
#       if [ -n "${SEL:-}" ]; then
#         CHOSEN_LABEL="${SEL%%|*}"
#         CHOSEN_ID="${SEL##*|}"
#       fi
#     fi
#     echo "[debug] CHOSEN_LABEL='${CHOSEN_LABEL:-}'  CHOSEN_ID='${CHOSEN_ID:-}'"

#     if [ -z "${CHOSEN_ID:-}" ]; then
#       echo "[error] Aucune clé privée trouvée sur le token '${SOFTHSM_TOKEN_LABEL}'." >&2
#       exit 1
#     fi
#     # URI PKCS#11 (RFC 7512). Ne PAS préfixer par "engine:" pour stunnel.
#     KEY_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};id=${CHOSEN_ID};type=private"
#   fi
# else
#   KEY_URI="/certs/server/pg_pkcs11/server.key"
# fi

# echo "[debug] KEY_URI -> ${KEY_URI}"

# # ---- générer stunnel.conf depuis le template ----
# export SERVICE_NAME ACCEPT_PORT CONNECT_HOST CONNECT_PORT
# envsubst < /stunnel.conf.template > /etc/stunnel/stunnel.conf

# # Remplacer les placeholders restants
# sed -i "s|@PKCS11_MODULE_PATH@|${PKCS11_MODULE_PATH}|" /etc/stunnel/stunnel.conf
# sed -i "s|@SOFTHSM_USER_PIN@|${SOFTHSM_USER_PIN}|" /etc/stunnel/stunnel.conf
# sed -i "s|@KEY_URI@|${KEY_URI}|" /etc/stunnel/stunnel.conf

# echo "----- /etc/stunnel/stunnel.conf -----"
# sed -n '1,200p' /etc/stunnel/stunnel.conf
# echo "-------------------------------------"

# # Garde-fou : s'assurer qu'il ne reste aucun placeholder
# if grep -q '@PKCS11_MODULE_PATH@\|@SOFTHSM_USER_PIN@\|@KEY_URI@' /etc/stunnel/stunnel.conf; then
#   echo "[error] Placeholder non remplacé dans stunnel.conf" >&2
#   exit 1
# fi

# # Vérif présence engine pkcs11 dans OpenSSL (indicatif)
# echo "[debug] openssl engine -t -c pkcs11"
# openssl engine -t -c pkcs11 || true

# # ---- lancement stunnel ----
# exec /usr/bin/stunnel /etc/stunnel/stunnel.conf
