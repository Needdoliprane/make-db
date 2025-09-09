#!/usr/bin/env bash
set -euo pipefail

# Copie des certs dans PGDATA avec les bons droits (Postgres est strict)
install -m 600 /certs/server/pg_tls/server.key  "$PGDATA/server.key"
install -m 644 /certs/server/pg_tls/server.crt  "$PGDATA/server.crt"
install -m 644 /certs/ca/ca.crt                 "$PGDATA/root.crt"
chown postgres:postgres "$PGDATA/server.key" "$PGDATA/server.crt" "$PGDATA/root.crt"

# Active SSL et pointe sur les fichiers locaux
cat >> "$PGDATA/postgresql.conf" <<EOF
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
ssl_ca_file = 'root.crt'
EOF

# Écrit UNE SEULE règle hostssl selon le mode (ordre important)
if [ "${REQUIRE_CLIENT_CERT:-0}" = "1" ]; then
  # mTLS: exige un cert client signé par notre CA + mot de passe SCRAM
  echo "hostssl all all all scram-sha-256 clientcert=verify-ca" >> "$PGDATA/pg_hba.conf"
else
  # TLS simple: mot de passe SCRAM, pas de cert client obligatoire
  echo "hostssl all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
fi
