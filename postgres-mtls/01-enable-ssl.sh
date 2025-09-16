#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Script d’init exécuté par l’entrypoint Postgres au premier démarrage.
# Il déploie les certs mTLS dans PGDATA avec les bons droits,
# et active ssl + clientcert.
# Requiert un volume /certs avec:
#   /certs/ca/ca.crt
#   /certs/server/pg_mtls/server.crt
#   /certs/server/pg_mtls/server.key
# -----------------------------------------------------------------------------

REQ_CC="${REQUIRE_CLIENT_CERT:-1}"       # mTLS par défaut
CERT_PROFILE="${CERT_PROFILE:-pg_mtls}"  # verrouillé sur pg_mtls ici

CERT_DIR="/certs"
SERVER_DIR="${CERT_DIR}/server/${CERT_PROFILE}"
CA_FILE="${CERT_DIR}/ca/ca.crt"

echo "[pg-mtls] REQUIRE_CLIENT_CERT=${REQ_CC}"
echo "[pg-mtls] CERT_PROFILE=${CERT_PROFILE}"
echo "[pg-mtls] Using server certs in: ${SERVER_DIR}"

# Sanity checks
if [[ ! -f "${SERVER_DIR}/server.crt" || ! -f "${SERVER_DIR}/server.key" ]]; then
  echo "[pg-mtls][FATAL] Missing server cert or key in ${SERVER_DIR}/ (expected server.crt/server.key)" >&2
  exit 1
fi
if [[ ! -f "${CA_FILE}" ]]; then
  echo "[pg-mtls][FATAL] Missing CA file at ${CA_FILE}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Copie des certs dans PGDATA avec les bons droits
# -----------------------------------------------------------------------------
install -m 600 "${SERVER_DIR}/server.key"  "${PGDATA}/server.key"
install -m 644 "${SERVER_DIR}/server.crt"  "${PGDATA}/server.crt"
install -m 644 "${CA_FILE}"                "${PGDATA}/root.crt"
chown postgres:postgres "${PGDATA}/server.key" "${PGDATA}/server.crt" "${PGDATA}/root.crt"

# -----------------------------------------------------------------------------
# postgresql.conf : active SSL + chemins
# -----------------------------------------------------------------------------
# Nettoie d’éventuelles lignes précédentes ssl_*
sed -i '/^ssl[ _]/d' "${PGDATA}/postgresql.conf" || true

cat >> "${PGDATA}/postgresql.conf" <<EOF
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_ca_file = 'root.crt'
#ssl_min_protocol_version = 'TLSv1.2'
#ssl_prefer_server_ciphers = on
EOF

# -----------------------------------------------------------------------------
# pg_hba.conf : exige un cert client signé par notre CA + SCRAM
# -----------------------------------------------------------------------------
# (si tu veux être ultra sélectif, remplace 'all all all' par un réseau/IP)
echo "hostssl all all all scram-sha-256 clientcert=verify-ca" >> "${PGDATA}/pg_hba.conf"

echo "[pg-mtls] TLS+mTLS configuré."
