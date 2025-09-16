#!/bin/sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

SSL_DIR=/etc/mysql/ssl
INIT_DIR=/etc/mysql/init
PORT="${MYSQL_MTLS_PORT:-3306}"

mkdir -p "$SSL_DIR" "$INIT_DIR"
cp /ssl-src/ca/ca.crt                      "$SSL_DIR/ca.crt"
cp /ssl-src/server/mysql_mtls/server.crt   "$SSL_DIR/server.crt"
cp /ssl-src/server/mysql_mtls/server.key   "$SSL_DIR/server.key"
chown -R mysql:mysql "$SSL_DIR" "$INIT_DIR"
chmod 600 "$SSL_DIR/server.key"

pw_sql=$(printf "%s" "$MYSQL_ROOT_PASSWORD" | sed "s/'/''/g")

# Fichier pour init root avec mTLS obligatoire (REQUIRE X509)
cat > "$INIT_DIR/root_bootstrap.sql" <<EOF
-- Accès global
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}' REQUIRE X509;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

-- Accès réseau Docker
CREATE USER IF NOT EXISTS 'root'@'172.%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
ALTER USER 'root'@'172.%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}' REQUIRE X509;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'172.%' WITH GRANT OPTION;

-- Accès réseau local (poste)
CREATE USER IF NOT EXISTS 'root'@'192.168.1.%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
ALTER USER 'root'@'192.168.1.%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}' REQUIRE X509;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'192.168.1.%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
EOF

chown mysql:mysql "$INIT_DIR/root_bootstrap.sql"
chmod 600 "$INIT_DIR/root_bootstrap.sql"

exec docker-entrypoint.sh mysqld \
  --port="${PORT}" \
  --require_secure_transport=ON \
  --ssl_ca="$SSL_DIR/ca.crt" \
  --ssl_cert="$SSL_DIR/server.crt" \
  --ssl_key="$SSL_DIR/server.key" \
  --tls_version=TLSv1.2,TLSv1.3 \
  --skip-name-resolve \
  --init-file="$INIT_DIR/root_bootstrap.sql"
