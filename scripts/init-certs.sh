#!/usr/bin/env bash
set -euo pipefail

# --------- Démarrage HSM (réseau/volume + container) ----------
COMPOSE_BASE="${COMPOSE_BASE:-docker-compose.base.yml}"

log(){ printf "$*"; }

ensure_network(){
  if ! docker network inspect dbnet >/dev/null 2>&1; then
    log "create network dbnet"
    docker network create dbnet >/dev/null
  fi
}
ensure_volume(){
  if ! docker volume inspect softhsm >/dev/null 2>&1; then
    log "create volume softhsm"
    docker volume create softhsm >/dev/null
  fi
}
wait_running(){ # $1=name
  for _ in {1..80}; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; fi
    sleep 0.25
  done
  log "✗ timeout: $1 not running"; exit 1
}

ensure_network
ensure_volume
log "up softhsm via compose ($COMPOSE_BASE)…"
docker compose -f "$COMPOSE_BASE" up -d --build softhsm
wait_running softhsm

# prépare le FS dans le container HSM
docker exec softhsm bash -lc 'set -e
mkdir -p /var/lib/softhsm/tokens
[ -f /etc/softhsm2.conf ] || cat >/etc/softhsm2.conf <<EOF
directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend = file
slots.removable = true
EOF
'

# --------- Variables habituelles ----------
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
DIR="${1:-./certs}"
CN="${2:-${CERT_CN_BASE:-localhost}}"

SOFTHSM_TOKEN_LABEL="${SOFTHSM_TOKEN_LABEL:-DOLICORP}"
SOFTHSM_SO_PIN="${SOFTHSM_SO_PIN:-so1234}"
SOFTHSM_USER_PIN="${SOFTHSM_USER_PIN:-1234}"

mkdir -p "$DIR/ca" "$DIR/server"

# ---------- Helpers ----------
# Construit la section [alt] pour subjectAltName à partir d'un CSV
# Entrées acceptées : "DNS:foo", "IP:1.2.3.4" ou "foo" (=> DNS:foo)
make_alt_section() {
  local csv="$1"
  local i=1
  local out=""
  local token val
  IFS=',' read -r -a arr <<< "$csv"
  for token in "${arr[@]}"; do
    token="$(echo "$token" | xargs)"  # trim
    if [[ "$token" == IP:* ]]; then
      val="${token#IP:}"
      out+="IP.$i = $val"$'\n'
    elif [[ "$token" == DNS:* ]]; then
      val="${token#DNS:}"
      out+="DNS.$i = $val"$'\n'
    else
      out+="DNS.$i = $token"$'\n'
    fi
    i=$((i+1))
  done
  printf "%s" "$out"
}

# ---------- CA (avec extensions v3_ca) ----------
if [ ! -f "$DIR/ca/ca.key" ]; then
  "$OPENSSL_BIN" genrsa -out "$DIR/ca/ca.key" 4096
fi

CA_CNF="$(mktemp)"
cat >"$CA_CNF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
default_md         = sha256
[ dn ]
CN = ${CN} Test CA
[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
EOF

# (on régénère la CA à chaque run, comme avant, mais avec v3_ca)
"$OPENSSL_BIN" req -x509 -new -nodes -key "$DIR/ca/ca.key" \
  -days 3650 -config "$CA_CNF" -out "$DIR/ca/ca.crt"
rm -f "$CA_CNF"

# ---------- Image utilitaire (openssl + pkcs11-tool) ----------
TLP_IMG="$(docker build -q ./tlsproxy)"

# bootstrap commun pour les conteneurs utilitaires (conf softhsm + openssl pkcs11)
bootstrap_runner='
set -eu
# SoftHSM conf
cat >/etc/softhsm2.conf <<EOF
directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend = file
slots.removable = true
EOF
# OpenSSL pkcs11 conf (détecte pkcs11.so selon arch)
DYN=""
for p in /usr/lib/*/engines-3/pkcs11.so /usr/lib/engines-3/pkcs11.so; do
  [ -f "$p" ] && { DYN="$p"; break; }
done
[ -n "$DYN" ] || { echo "[runner] pkcs11 engine not found (libengine-pkcs11-openssl manquant ?)"; exit 1; }
cat >/etc/ssl/openssl-pkcs11.cnf <<EOF
openssl_conf = default_conf
[ default_conf ]
engines = engine_section
[ engine_section ]
pkcs11 = pkcs11_section
[ pkcs11_section ]
engine_id = pkcs11
dynamic_path = ${DYN}
MODULE_PATH  = /usr/lib/softhsm/libsofthsm2.so
INIT = 0
EOF
export SOFTHSM2_CONF=/etc/softhsm2.conf
export OPENSSL_CONF=/etc/ssl/openssl-pkcs11.cnf
'

# --- Init token, directement dans le conteneur softhsm (idempotent) ---
docker exec \
  -e SOFTHSM2_CONF=/etc/softhsm2.conf \
  -e SOFTHSM_TOKEN_LABEL="${SOFTHSM_TOKEN_LABEL}" \
  -e SOFTHSM_SO_PIN="${SOFTHSM_SO_PIN}" \
  -e SOFTHSM_USER_PIN="${SOFTHSM_USER_PIN}" \
  softhsm bash -lc '
set -eu
MOD=/usr/lib/softhsm/libsofthsm2.so

mkdir -p /var/lib/softhsm/tokens
[ -f /etc/softhsm2.conf ] || cat >/etc/softhsm2.conf <<EOF
directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend = file
slots.removable = true
EOF

# Compter les tokens "DOLICORP" (via le bon module)
count="$(pkcs11-tool --module "$MOD" -T 2>/dev/null \
  | awk "/token label[[:space:]]*:[[:space:]]*${SOFTHSM_TOKEN_LABEL}/{c++} END{print c+0}")"

if [ "${count}" -eq 1 ]; then
  echo "[hsm] token ${SOFTHSM_TOKEN_LABEL} déjà présent (1) → OK, pas de réinit"
elif [ "${count}" -eq 0 ]; then
  echo "[hsm] aucun token ${SOFTHSM_TOKEN_LABEL} → init"
  softhsm2-util --init-token --free \
    --label "${SOFTHSM_TOKEN_LABEL}" \
    --so-pin "${SOFTHSM_SO_PIN}" \
    --pin    "${SOFTHSM_USER_PIN}"
else
  echo "[hsm] ${count} tokens ${SOFTHSM_TOKEN_LABEL} → purge + réinit"
  rm -rf /var/lib/softhsm/tokens/* || true
  softhsm2-util --init-token --free \
    --label "${SOFTHSM_TOKEN_LABEL}" \
    --so-pin "${SOFTHSM_SO_PIN}" \
    --pin    "${SOFTHSM_USER_PIN}"
fi

echo "[hsm] slots:"
pkcs11-tool --module "$MOD" -T || true

# Sanity: login user par label (échoue si doublon/label KO)
pkcs11-tool --module "$MOD" \
  --token-label "${SOFTHSM_TOKEN_LABEL}" \
  --login --pin "${SOFTHSM_USER_PIN}" \
  --list-objects --type privkey || true
'

# ---------- Génération HSM (terminators PKCS#11) ----------
gen_one() {
  local svc="$1" id="$2" label="$3" san_csv="$4"
  local OUT="$DIR/server/$svc"
  mkdir -p "$OUT"

  # 1) Pair RSA dans HSM si absente
  docker run --rm --entrypoint /bin/sh \
    -e SOFTHSM2_CONF=/etc/softhsm2.conf \
    -v softhsm:/var/lib/softhsm \
    "$TLP_IMG" -lc "
$bootstrap_runner
MOD=/usr/lib/softhsm/libsofthsm2.so
if ! pkcs11-tool --module \"\$MOD\" --token-label \"${SOFTHSM_TOKEN_LABEL}\" \
      --login --pin \"${SOFTHSM_USER_PIN}\" --list-objects --type privkey 2>/dev/null \
      | grep -q \"label:[[:space:]]*${label}\$\"; then
  echo \"[hsm] keypair gen id=${id} label=${label}\"
  pkcs11-tool --module \"\$MOD\" --token-label \"${SOFTHSM_TOKEN_LABEL}\" \
    --login --pin \"${SOFTHSM_USER_PIN}\" --session-rw \
    --keypairgen --key-type rsa:2048 \
    --usage-sign --usage-decrypt \
    --id ${id} --label \"${label}\"
fi
"

  # 2) Fichier de config CSR avec SAN corrects
  local REQ="$OUT/req.cnf"
  {
    echo "[ req ]"
    echo "prompt             = no"
    echo "distinguished_name = dn"
    echo "req_extensions     = v3_req"
    echo "default_md         = sha256"
    echo "[ dn ]"
    echo "CN = ${CN}"
    echo "[ v3_req ]"
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage         = digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectAltName   = @alt"
    echo "[ alt ]"
    make_alt_section "$san_csv"
  } >"$REQ"

  # 3) CSR via clé privée HSM
  docker run --rm --entrypoint /bin/sh \
    -e SOFTHSM2_CONF=/etc/softhsm2.conf \
    -v "$(pwd)/$DIR:/certs" -v softhsm:/var/lib/softhsm \
    "$TLP_IMG" -lc "
$bootstrap_runner
openssl req -new -sha256 -keyform engine -engine pkcs11 \
  -key 'pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${label};type=private;pin-value=${SOFTHSM_USER_PIN}' \
  -config '/certs/server/${svc}/req.cnf' \
  -out '/certs/server/${svc}/server.csr'
"

  # 4) Signature par la CA (extensions serveur)
  local EXT="$(mktemp)"
  {
    echo "subjectAltName=@alt"
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=serverAuth"
    echo "[alt]"
    make_alt_section "$san_csv"
  } >"$EXT"

  "$OPENSSL_BIN" x509 -req -in "$OUT/server.csr" \
    -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
    -days 825 -sha256 -extfile "$EXT" -out "$OUT/server.crt"

  # 5) Import du cert dans le HSM (même id + label)
  "$OPENSSL_BIN" x509 -in "$OUT/server.crt" -outform der -out "$OUT/server.der"
  docker run --rm --entrypoint /bin/sh \
    -e SOFTHSM2_CONF=/etc/softhsm2.conf \
    -v "$(pwd)/$DIR:/certs" -v softhsm:/var/lib/softhsm \
    "$TLP_IMG" -lc "
$bootstrap_runner
MOD=/usr/lib/softhsm/libsofthsm2.so
pkcs11-tool --module \"\$MOD\" --token-label '${SOFTHSM_TOKEN_LABEL}' \
  --login --pin '${SOFTHSM_USER_PIN}' \
  --write-object '/certs/server/${svc}/server.der' --type cert \
  --label '${label}' --id '${id}'
"

  # 6) Nettoyage local
  rm -f "$EXT" "$OUT/server.der" "$OUT/req.cnf"
  echo "✅ HSM prêt pour ${svc} (label=${label}, id=${id})"
}

# ---------- Génération FS (TLS/mTLS natif) ----------
gen_server_fs () {
  # $1 = dir (ex: pg_tls), $2 = SAN CSV typé (ex: "DNS:localhost,IP:127.0.0.1,DNS:pg-tls")
  local svc="$1"
  local san_csv="$2"
  local OUT="$DIR/server/${svc}"

  mkdir -p "$OUT"

  # key
  [ -f "$OUT/server.key" ] || $OPENSSL_BIN genrsa -out "$OUT/server.key" 2048
  chmod 644 "$OUT/server.key"

  # CSR config avec SAN corrects
  local REQ ALT_CONTENT
  REQ="$(mktemp)"
  ALT_CONTENT="$(make_alt_section "$san_csv")"
  cat >"$REQ" <<EOF
[ req ]
prompt             = no
distinguished_name = dn
req_extensions     = v3_req
default_md         = sha256
[ dn ]
CN = ${CN}
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt
[ alt ]
${ALT_CONTENT}
EOF

  # CSR + cert
  $OPENSSL_BIN req -new -key "$OUT/server.key" -config "$REQ" -out "$OUT/server.csr"
  $OPENSSL_BIN x509 -req -in "$OUT/server.csr" \
    -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
    -days 825 -sha256 -extfile "$REQ" -extensions v3_req \
    -out "$OUT/server.crt"

  rm -f "$REQ" "$OUT/server.csr"

  cat "$OUT/server.key" "$OUT/server.crt" > "$OUT/server.pem"
  echo "✅ FS cert prêt pour $svc"
}

gen_client_cert () {
  # /certs/client/client.key|crt (avec EKU clientAuth)
  local COUT="$DIR/client"
  mkdir -p "$COUT"
  [ -f "$COUT/client.key" ] || $OPENSSL_BIN genrsa -out "$COUT/client.key" 2048
  chmod 600 "$COUT/client.key"

  local CFG="$COUT/client_req.cnf"
  cat >"$CFG" <<'EOF'
[ req ]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no
default_md         = sha256
[ dn ]
CN = client
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

  local REQ="$COUT/client.csr"
  $OPENSSL_BIN req -new -key "$COUT/client.key" -config "$CFG" -out "$REQ"

  $OPENSSL_BIN x509 -req -in "$REQ" \
    -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
    -days 825 -sha256 -extfile "$CFG" -extensions v3_req \
    -out "$COUT/client.crt"

  rm -f "$REQ" "$CFG"

  cat "$COUT/client.key" "$COUT/client.crt" > "$COUT/client.pem"

  echo "✅ Cert client mTLS généré (EKU=clientAuth)"
}

# ---------- Serveurs FS (TLS natif et mTLS natif) ----------
gen_server_fs pg_tls      "DNS:localhost,IP:127.0.0.1,DNS:pg-tls"
gen_server_fs pg_mtls     "DNS:localhost,IP:127.0.0.1,DNS:pg-mtls"
gen_server_fs mysql_tls   "DNS:localhost,IP:127.0.0.1,DNS:mysql-tls"
gen_server_fs mysql_mtls  "DNS:localhost,IP:127.0.0.1,DNS:mysql-mtls"
gen_server_fs mariadb_tls  "DNS:localhost,IP:127.0.0.1,DNS:mariadb-tls"
gen_server_fs mariadb_mtls "DNS:localhost,IP:127.0.0.1,DNS:mariadb-mtls"
gen_server_fs mongo_tls    "DNS:localhost,IP:127.0.0.1,DNS:mongo-tls"
gen_server_fs mongo_mtls   "DNS:localhost,IP:127.0.0.1,DNS:mongo-mtls"

# ---------- Client mTLS ----------
gen_client_cert

# ---------- Génération pour chaque service PKCS#11 ----------
gen_one pg_pkcs11      01 svc-pg      "DNS:localhost,IP:127.0.0.1,DNS:pg-pkcs11-frontend"
gen_one mysql_pkcs11   02 svc-mysql   "DNS:localhost,IP:127.0.0.1,DNS:mysql-pkcs11-frontend"
gen_one mariadb_pkcs11 03 svc-mariadb "DNS:localhost,IP:127.0.0.1,DNS:mariadb-pkcs11-frontend"
gen_one mongo_pkcs11   04 svc-mongo   "DNS:localhost,IP:127.0.0.1,DNS:mongo-pkcs11-frontend"

echo "✅ Certs générés/importés (token=${SOFTHSM_TOKEN_LABEL})"


# #!/usr/bin/env bash
# set -euo pipefail

# # --------- Démarrage HSM (réseau/volume + container) ----------
# COMPOSE_BASE="${COMPOSE_BASE:-docker-compose.base.yml}"

# log(){ printf "$*"; }

# ensure_network(){
#   if ! docker network inspect dbnet >/dev/null 2>&1; then
#     log "create network dbnet"
#     docker network create dbnet >/dev/null
#   fi
# }
# ensure_volume(){
#   if ! docker volume inspect softhsm >/dev/null 2>&1; then
#     log "create volume softhsm"
#     docker volume create softhsm >/dev/null
#   fi
# }
# wait_running(){ # $1=name
#   for _ in {1..80}; do
#     if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; then return 0; fi
#     sleep 0.25
#   done
#   log "✗ timeout: $1 not running"; exit 1
# }

# ensure_network
# ensure_volume
# log "up softhsm via compose ($COMPOSE_BASE)…"
# docker compose -f "$COMPOSE_BASE" up -d --build softhsm
# wait_running softhsm

# # prépare le FS dans le container HSM
# docker exec softhsm bash -lc 'set -e
# mkdir -p /var/lib/softhsm/tokens
# [ -f /etc/softhsm2.conf ] || cat >/etc/softhsm2.conf <<EOF
# directories.tokendir = /var/lib/softhsm/tokens
# objectstore.backend = file
# slots.removable = true
# EOF
# '

# # --------- Variables habituelles ----------
# OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
# DIR="${1:-./certs}"
# CN="${2:-${CERT_CN_BASE:-localhost}}"

# SOFTHSM_TOKEN_LABEL="${SOFTHSM_TOKEN_LABEL:-DOLICORP}"
# SOFTHSM_SO_PIN="${SOFTHSM_SO_PIN:-so1234}"
# SOFTHSM_USER_PIN="${SOFTHSM_USER_PIN:-1234}"

# mkdir -p "$DIR/ca" "$DIR/server"

# # CA idempotente
# if [ ! -f "$DIR/ca/ca.key" ]; then
#   "$OPENSSL_BIN" genrsa -out "$DIR/ca/ca.key" 4096
# fi
# "$OPENSSL_BIN" req -x509 -new -nodes -key "$DIR/ca/ca.key" -sha256 -days 3650 \
#   -out "$DIR/ca/ca.crt" -subj "/CN=${CN} Test CA"

# # Image utilitaire (openssl + pkcs11-tool)
# TLP_IMG="$(docker build -q ./tlsproxy)"

# # bootstrap commun pour les conteneurs utilitaires (conf softhsm + openssl pkcs11)
# bootstrap_runner='
# set -eu
# # SoftHSM conf
# cat >/etc/softhsm2.conf <<EOF
# directories.tokendir = /var/lib/softhsm/tokens
# objectstore.backend = file
# slots.removable = true
# EOF
# # OpenSSL pkcs11 conf (détecte pkcs11.so selon arch)
# DYN=""
# for p in /usr/lib/*/engines-3/pkcs11.so /usr/lib/engines-3/pkcs11.so; do
#   [ -f "$p" ] && { DYN="$p"; break; }
# done
# [ -n "$DYN" ] || { echo "[runner] pkcs11 engine not found (libengine-pkcs11-openssl manquant ?)"; exit 1; }
# cat >/etc/ssl/openssl-pkcs11.cnf <<EOF
# openssl_conf = default_conf
# [ default_conf ]
# engines = engine_section
# [ engine_section ]
# pkcs11 = pkcs11_section
# [ pkcs11_section ]
# engine_id = pkcs11
# dynamic_path = ${DYN}
# MODULE_PATH  = /usr/lib/softhsm/libsofthsm2.so
# INIT = 0
# EOF
# export SOFTHSM2_CONF=/etc/softhsm2.conf
# export OPENSSL_CONF=/etc/ssl/openssl-pkcs11.cnf
# '

# # --- Init token, directement dans le conteneur softhsm (idempotent) ---
# docker exec \
#   -e SOFTHSM2_CONF=/etc/softhsm2.conf \
#   -e SOFTHSM_TOKEN_LABEL="${SOFTHSM_TOKEN_LABEL}" \
#   -e SOFTHSM_SO_PIN="${SOFTHSM_SO_PIN}" \
#   -e SOFTHSM_USER_PIN="${SOFTHSM_USER_PIN}" \
#   softhsm bash -lc '
# set -eu
# MOD=/usr/lib/softhsm/libsofthsm2.so

# mkdir -p /var/lib/softhsm/tokens
# [ -f /etc/softhsm2.conf ] || cat >/etc/softhsm2.conf <<EOF
# directories.tokendir = /var/lib/softhsm/tokens
# objectstore.backend = file
# slots.removable = true
# EOF

# # Compter les tokens "DOLICORP" (via le bon module)
# count="$(pkcs11-tool --module "$MOD" -T 2>/dev/null \
#   | awk "/token label[[:space:]]*:[[:space:]]*${SOFTHSM_TOKEN_LABEL}/{c++} END{print c+0}")"

# if [ "${count}" -eq 1 ]; then
#   echo "[hsm] token ${SOFTHSM_TOKEN_LABEL} déjà présent (1) → OK, pas de réinit"
# elif [ "${count}" -eq 0 ]; then
#   echo "[hsm] aucun token ${SOFTHSM_TOKEN_LABEL} → init"
#   softhsm2-util --init-token --free \
#     --label "${SOFTHSM_TOKEN_LABEL}" \
#     --so-pin "${SOFTHSM_SO_PIN}" \
#     --pin    "${SOFTHSM_USER_PIN}"
# else
#   echo "[hsm] ${count} tokens ${SOFTHSM_TOKEN_LABEL} → purge + réinit"
#   rm -rf /var/lib/softhsm/tokens/* || true
#   softhsm2-util --init-token --free \
#     --label "${SOFTHSM_TOKEN_LABEL}" \
#     --so-pin "${SOFTHSM_SO_PIN}" \
#     --pin    "${SOFTHSM_USER_PIN}"
# fi

# echo "[hsm] slots:"
# pkcs11-tool --module "$MOD" -T || true

# # Sanity: login user par label (échoue si doublon/label KO)
# pkcs11-tool --module "$MOD" \
#   --token-label "${SOFTHSM_TOKEN_LABEL}" \
#   --login --pin "${SOFTHSM_USER_PIN}" \
#   --list-objects --type privkey || true
# '



# gen_one() {
#   local svc="$1" id="$2" label="$3" san_csv="$4"
#   local OUT="$DIR/server/$svc"
#   mkdir -p "$OUT"

#   # --- 1) Générer la paire RSA dans le HSM si absente ---
#   docker run --rm --entrypoint /bin/sh \
#     -e SOFTHSM2_CONF=/etc/softhsm2.conf \
#     -v softhsm:/var/lib/softhsm \
#     "$TLP_IMG" -lc "
# $bootstrap_runner
# MOD=/usr/lib/softhsm/libsofthsm2.so
# if ! pkcs11-tool --module \"\$MOD\" --token-label \"${SOFTHSM_TOKEN_LABEL}\" \
#       --login --pin \"${SOFTHSM_USER_PIN}\" --list-objects --type privkey 2>/dev/null \
#       | grep -q \"label:[[:space:]]*${label}\$\"; then
#   echo \"[hsm] keypair gen id=${id} label=${label}\"
#   pkcs11-tool --module \"\$MOD\" --token-label \"${SOFTHSM_TOKEN_LABEL}\" \
#     --login --pin \"${SOFTHSM_USER_PIN}\" --session-rw \
#     --keypairgen --key-type rsa:2048 \
#     --usage-sign --usage-decrypt \
#     --id ${id} --label \"${label}\"
# fi
# "

#   # --- 2) CSR config (SAN inline) ---
#   local ALT REQ EXT i d
#   ALT="$(mktemp)"
#   i=1
#   IFS=',' 
#   for d in $san_csv; do
#     echo "DNS.$i = $d" >> "$ALT"
#     i=$((i+1))
#   done
#   unset IFS

#   REQ="$(mktemp)"
#   cat >"$REQ" <<EOF
# [ req ]
# prompt             = no
# distinguished_name = dn
# req_extensions     = v3_req
# default_md         = sha256
# [ dn ]
# CN = ${CN}
# [ v3_req ]
# basicConstraints = CA:FALSE
# keyUsage         = digitalSignature, keyEncipherment
# extendedKeyUsage = serverAuth
# subjectAltName   = @alt
# [ alt ]
# $(cat "$ALT")
# EOF

#   # --- 3) CSR depuis la clé privée HSM (sélection par label) ---
#   docker run --rm --entrypoint /bin/sh \
#     -e SOFTHSM2_CONF=/etc/softhsm2.conf \
#     -v "$(pwd)/$DIR:/certs" -v softhsm:/var/lib/softhsm \
#     "$TLP_IMG" -lc "
# $bootstrap_runner
# openssl req -new -sha256 -keyform engine -engine pkcs11 \
#   -key 'pkcs11:token=${SOFTHSM_TOKEN_LABEL};object=${label};type=private;pin-value=${SOFTHSM_USER_PIN}' \
#   -config - -out '/certs/server/${svc}/server.csr' <<'EOCFG'
# $(cat "$REQ")
# EOCFG
# "

#   # --- 4) Signature par la CA ---
#   EXT="$(mktemp)"
#   cat >"$EXT" <<EOF
# subjectAltName=@alt
# basicConstraints=CA:FALSE
# keyUsage=digitalSignature,keyEncipherment
# extendedKeyUsage=serverAuth
# [alt]
# $(cat "$ALT")
# EOF
#   "$OPENSSL_BIN" x509 -req -in "$OUT/server.csr" \
#     -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
#     -days 825 -sha256 -extfile "$EXT" -out "$OUT/server.crt"

#   # --- 5) Import du cert dans le HSM (même id + label) ---
#   "$OPENSSL_BIN" x509 -in "$OUT/server.crt" -outform der -out "$OUT/server.der"
#   docker run --rm --entrypoint /bin/sh \
#     -e SOFTHSM2_CONF=/etc/softhsm2.conf \
#     -v "$(pwd)/$DIR:/certs" -v softhsm:/var/lib/softhsm \
#     "$TLP_IMG" -lc "
# $bootstrap_runner
# MOD=/usr/lib/softhsm/libsofthsm2.so
# pkcs11-tool --module \"\$MOD\" --token-label '${SOFTHSM_TOKEN_LABEL}' \
#   --login --pin '${SOFTHSM_USER_PIN}' \
#   --write-object '/certs/server/${svc}/server.der' --type cert \
#   --label '${label}' --id '${id}'
# "

#   # --- 6) Nettoyage local ---
#   rm -f "$ALT" "$REQ" "$EXT" "$OUT/server.der"
#   echo "✅ HSM prêt pour ${svc} (label=${label}, id=${id})"
# }

# gen_server_fs () {
#   # $1 = dir (ex: pg_tls), $2 = SAN CSV (ex: "localhost,127,0,0,1,pg-tls")
#   local svc="$1"
#   local san_csv="$2"
#   local OUT="$DIR/server/${svc}"

#   mkdir -p "$OUT"

#   # key
#   [ -f "$OUT/server.key" ] || $OPENSSL_BIN genrsa -out "$OUT/server.key" 2048
#   chmod 644 "$OUT/server.key"

#   # SAN -> cnf
#   local ALT REQ i d
#   ALT="$(mktemp)"
#   i=1
#   IFS=',' 
#   for d in $san_csv; do
#     echo "DNS.$i = $d" >> "$ALT"
#     i=$((i+1))
#   done
#   unset IFS

#   REQ="$(mktemp)"
#   cat >"$REQ" <<EOF
# [ req ]
# prompt             = no
# distinguished_name = dn
# req_extensions     = v3_req
# default_md         = sha256
# [ dn ]
# CN = ${CN}
# [ v3_req ]
# basicConstraints = CA:FALSE
# keyUsage         = digitalSignature, keyEncipherment
# extendedKeyUsage = serverAuth
# subjectAltName   = @alt
# [ alt ]
# $(cat "$ALT")
# EOF

#   # CSR + cert
#   $OPENSSL_BIN req -new -key "$OUT/server.key" -config "$REQ" -out "$OUT/server.csr"
#   $OPENSSL_BIN x509 -req -in "$OUT/server.csr" \
#     -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
#     -days 825 -sha256 -extfile "$REQ" -extensions v3_req \
#     -out "$OUT/server.crt"

#   rm -f "$ALT" "$REQ" "$OUT/server.csr"

#   cat "$OUT/server.key" "$OUT/server.crt" > "$OUT/server.pem"
#   echo "✅ FS cert prêt pour $svc"
# }

# gen_client_cert () {
#   # /certs/client/client.key|crt
#   local COUT="$DIR/client"
#   mkdir -p "$COUT"
#   [ -f "$COUT/client.key" ] || $OPENSSL_BIN genrsa -out "$COUT/client.key" 2048
#   chmod 600 "$COUT/client.key"

#   local REQ="$COUT/client.csr"
#   $OPENSSL_BIN req -new -key "$COUT/client.key" -subj "/CN=client" -out "$REQ"

#   $OPENSSL_BIN x509 -req -in "$REQ" \
#     -CA "$DIR/ca/ca.crt" -CAkey "$DIR/ca/ca.key" -CAcreateserial \
#     -days 825 -sha256 \
#     -out "$COUT/client.crt"
#   rm -f "$REQ"

#   cat "$COUT/client.key" "$COUT/client.crt" > "$COUT/client.pem"

#   echo "✅ Cert client mTLS généré"
# }

# # serveurs FS (TLS natif et mTLS natif)
# gen_server_fs pg_tls    "localhost,127,0,0,1,pg-tls"
# gen_server_fs pg_mtls   "localhost,127,0,0,1,pg-mtls"
# gen_server_fs mysql_tls   "localhost,127,0,0,1,mysql-tls"
# gen_server_fs mysql_mtls  "localhost,127,0,0,1,mysql-mtls"
# gen_server_fs mariadb_tls  "localhost,127,0,0,1,mariadb-tls"
# gen_server_fs mariadb_mtls "localhost,127,0,0,1,mariadb-mtls"
# gen_server_fs mongo_tls    "localhost,127,0,0,1,mongo-tls"
# gen_server_fs mongo_mtls   "localhost,127,0,0,1,mongo-mtls"

# # client mTLS (utilisé par seeder et pour pg-mtls)
# gen_client_cert

# # Génération pour chaque service
# gen_one pg_pkcs11      01 svc-pg      "localhost,127,0,0,1,pg-pkcs11-frontend"
# gen_one mysql_pkcs11   02 svc-mysql   "localhost,127,0,0,1,mysql-pkcs11-frontend"
# gen_one mariadb_pkcs11 03 svc-mariadb "localhost,127,0,0,1,mariadb-pkcs11-frontend"
# gen_one mongo_pkcs11   04 svc-mongo   "localhost,127,0,0,1,mongo-pkcs11-frontend"

# echo "✅ Certs générés/importés (token=${SOFTHSM_TOKEN_LABEL})"
