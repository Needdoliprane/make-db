#!/usr/bin/env sh
set -eu

# --- Paramètres par défaut ---
: "${SERVICE_NAME:=pg_pkcs11}"
: "${ACCEPT_PORT:=35432}"
: "${CONNECT_HOST:=pg-pkcs11}"
: "${CONNECT_PORT:=5432}"
: "${ENABLE_PKCS11:=1}"

: "${SOFTHSM_TOKEN_LABEL:=DOLICORP}"
: "${SOFTHSM_USER_PIN:=1234}"

# Labels d’objets dans le HSM
: "${PKCS11_KEY_LABEL:=svc-pg}"        # clé privée dans le HSM
: "${PKCS11_CERT_LABEL:=svc-pg-cert}"  # certificat (on va l'importer)

# Attentes
: "${HSM_WAIT_SECONDS:=25}"
: "${CERT_WAIT_SECONDS:=30}"

# Chemins
CERT_FS="/certs/server/${SERVICE_NAME}/server.crt"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)"
PKCS11_MODULE_PATH="/usr/lib/softhsm/libsofthsm2.so"

# Env SoftHSM/OpenSSL (pas d'OPENSSL_CONF pour ne pas interférer)
export SOFTHSM2_CONF="/etc/softhsm2.conf"
export OPENSSL_ENGINES="/usr/lib/${ARCH}/engines-3"
export OPENSSL_MODULES="/usr/lib/${ARCH}/ossl-modules"
[ -n "${OPENSSL_CONF:-}" ] && unset OPENSSL_CONF || true

log(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

wait_for_fs_cert() {
  t=0
  while [ $t -lt "${CERT_WAIT_SECONDS}" ] && [ ! -s "$CERT_FS" ]; do
    sleep 1; t=$((t+1))
  done
  if [ ! -s "$CERT_FS" ]; then
    echo "Certificat introuvable: $CERT_FS"
    echo "Contenu /certs/server :"
    ls -lR /certs/server || true
    exit 1
  fi
}

print_slots() {
  echo "[HSM] Etat des slots :"
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" --list-slots 2>/dev/null || true
}

token_exists() {
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" --list-slots 2>/dev/null \
    | grep -q "token label[[:space:]]*:[[:space:]]*${SOFTHSM_TOKEN_LABEL}"
}

has_obj() {
  # $1 = type (privkey|cert), $2 = label
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
    --token-label "${SOFTHSM_TOKEN_LABEL}" --login --pin "${SOFTHSM_USER_PIN}" \
    --list-objects --type "$1" 2>/dev/null | grep -q "label:[[:space:]]*$2"
}

generate_key_if_needed() {
  if has_obj privkey "${PKCS11_KEY_LABEL}"; then
    log "[HSM] Clé '${PKCS11_KEY_LABEL}' déjà présente"
    return 0
  fi
  log "[HSM] Clé '${PKCS11_KEY_LABEL}' absente -> génération RSA 2048"
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
    --token-label "${SOFTHSM_TOKEN_LABEL}" --login --pin "${SOFTHSM_USER_PIN}" \
    --keypairgen --key-type rsa:2048 --label "${PKCS11_KEY_LABEL}"
}

import_cert_if_needed() {
  if has_obj cert "${PKCS11_CERT_LABEL}"; then
    log "[HSM] Certificat déjà présent (label=${PKCS11_CERT_LABEL})"
    return 0
  fi
  log "[HSM] Import du certificat dans SoftHSM (label=${PKCS11_CERT_LABEL})"
  CERT_DER="/tmp/${SERVICE_NAME}-server.der"
  openssl x509 -in "${CERT_FS}" -outform der -out "${CERT_DER}"
  pkcs11-tool --module "${PKCS11_MODULE_PATH}" \
    --token-label "${SOFTHSM_TOKEN_LABEL}" --login --pin "${SOFTHSM_USER_PIN}" \
    -y cert -a "${PKCS11_CERT_LABEL}" -w "${CERT_DER}"
  rm -f "${CERT_DER}"
}

ensure_token_and_key() {
  log "[HSM] Etat des slots (avant init) :"; print_slots

  if ! token_exists; then
    log "[HSM] Token '${SOFTHSM_TOKEN_LABEL}' absent -> création"
    softhsm2-util --init-token --free --label "${SOFTHSM_TOKEN_LABEL}" \
                  --so-pin "${SOFTHSM_USER_PIN}" --pin "${SOFTHSM_USER_PIN}"
    t=0
    until token_exists || [ $t -ge "${HSM_WAIT_SECONDS}" ]; do sleep 1; t=$((t+1)); done
    token_exists || die "Token SoftHSM '${SOFTHSM_TOKEN_LABEL}' introuvable après ${HSM_WAIT_SECONDS}s"
  fi

  generate_key_if_needed
  import_cert_if_needed

  log "[HSM] Etat des slots (après init) :"; print_slots
}

# 1) Cert sur disque
wait_for_fs_cert

# 2) Init HSM si demandé
if [ "${ENABLE_PKCS11}" = "1" ]; then
  ensure_token_and_key
fi

# 3) Générer stunnel.conf depuis le template
cp /stunnel.conf.template /etc/stunnel/stunnel.conf
sed -i \
  -e "s|@SERVICE_NAME@|${SERVICE_NAME}|g" \
  -e "s|@ACCEPT_PORT@|${ACCEPT_PORT}|g" \
  -e "s|@CONNECT_HOST@|${CONNECT_HOST}|g" \
  -e "s|@CONNECT_PORT@|${CONNECT_PORT}|g" \
  /etc/stunnel/stunnel.conf

if [ "${ENABLE_PKCS11}" = "1" ]; then
  PKCS11_ENGINE_SO="/usr/lib/${ARCH}/engines-3/pkcs11.so"
  ENGINE_GLOBAL="engine = dynamic\nengineCtrl = SO_PATH:${PKCS11_ENGINE_SO}\nengineCtrl = ID:pkcs11\nengineCtrl = LIST_ADD:1\nengineCtrl = LOAD\nengineCtrl = MODULE_PATH:${PKCS11_MODULE_PATH}\nengineCtrl = PIN:${SOFTHSM_USER_PIN}"

  # URIs RFC7512 pour cert & clé (tous deux dans le HSM)
  CERT_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${PKCS11_CERT_LABEL};type=cert"
  KEY_URI="pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${PKCS11_KEY_LABEL};type=private"

  sed -i "s|@ENGINE_GLOBAL@|${ENGINE_GLOBAL}|"   /etc/stunnel/stunnel.conf
  sed -i "s|@ENGINE_SERVICE@|engineId = pkcs11|" /etc/stunnel/stunnel.conf
  sed -i "s|@CERT_LINE@|cert = ${CERT_URI}|"     /etc/stunnel/stunnel.conf
  sed -i "s|@KEY_LINE@|key  = ${KEY_URI}|"       /etc/stunnel/stunnel.conf
else
  sed -i "s|@ENGINE_GLOBAL@||"                   /etc/stunnel/stunnel.conf
  sed -i "s|@ENGINE_SERVICE@||"                  /etc/stunnel/stunnel.conf
  sed -i "s|@CERT_LINE@|cert = ${CERT_FS}|"      /etc/stunnel/stunnel.conf
  sed -i "s|@KEY_LINE@|key  = /certs/server/${SERVICE_NAME}/server.key|" /etc/stunnel/stunnel.conf
fi

log "----- /etc/stunnel/stunnel.conf -----"
sed -n '1,220p' /etc/stunnel/stunnel.conf || true
log "-------------------------------------"

exec /usr/bin/stunnel /etc/stunnel/stunnel.conf
