#!/bin/sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

SSL_DIR=/etc/mysql/ssl
PORT="${MYSQL_MTLS_PORT:-3306}"

mkdir -p "$SSL_DIR"
cp /ssl-src/ca/ca.crt                     "$SSL_DIR/ca.crt"
cp /ssl-src/server/mysql_mtls/server.crt  "$SSL_DIR/server.crt"
cp /ssl-src/server/mysql_mtls/server.key  "$SSL_DIR/server.key"
chown -R mysql:mysql "$SSL_DIR"
chmod 600 "$SSL_DIR/server.key"

mkdir -p /docker-entrypoint-initdb.d
pw_sql=$(printf "%s" "$MYSQL_ROOT_PASSWORD" | sed "s/'/''/g")
cat > /docker-entrypoint-initdb.d/01_root_mtls.sql <<EOF
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'%' REQUIRE X509 PASSWORD EXPIRE NEVER ACCOUNT UNLOCK;
FLUSH PRIVILEGES;
EOF
chown -R mysql:mysql /docker-entrypoint-initdb.d

exec docker-entrypoint.sh mysqld \
  --port="${PORT}" \
  --require_secure_transport=ON \
  --ssl_ca=$SSL_DIR/ca.crt \
  --ssl_cert=$SSL_DIR/server.crt \
  --ssl_key=$SSL_DIR/server.key \
  --tls_version=TLSv1.2,TLSv1.3 \
  --skip-name-resolve
