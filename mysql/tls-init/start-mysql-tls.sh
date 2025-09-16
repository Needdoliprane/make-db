#!/bin/sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

SSL_DIR=/etc/mysql/ssl
INIT_DIR=/etc/mysql/init
PORT="${MYSQL_TLS_PORT:-3306}"

mkdir -p "$SSL_DIR" "$INIT_DIR"
cp /ssl-src/ca/ca.crt                    "$SSL_DIR/ca.crt"
cp /ssl-src/server/mysql_tls/server.crt  "$SSL_DIR/server.crt"
cp /ssl-src/server/mysql_tls/server.key  "$SSL_DIR/server.key"
chown -R mysql:mysql "$SSL_DIR" "$INIT_DIR"
chmod 600 "$SSL_DIR/server.key"

# SQL d’init (forcé à chaque boot)
pw_sql=$(printf "%s" "$MYSQL_ROOT_PASSWORD" | sed "s/'/''/g")
cat > "$INIT_DIR/root_bootstrap.sql" <<EOF
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'%' PASSWORD EXPIRE NEVER ACCOUNT UNLOCK;
FLUSH PRIVILEGES;
EOF
chown mysql:mysql "$INIT_DIR/root_bootstrap.sql"
chmod 600 "$INIT_DIR/root_bootstrap.sql"

exec docker-entrypoint.sh mysqld \
  --port="${PORT}" \
  --ssl_ca=/etc/mysql/ssl/ca.crt \
  --ssl_cert=/etc/mysql/ssl/server.crt \
  --ssl_key=/etc/mysql/ssl/server.key \
  --tls_version=TLSv1.2,TLSv1.3 \
  --skip-name-resolve \
  --init-file="$INIT_DIR/root_bootstrap.sql"


# #!/bin/sh
# set -eu

# : "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

# SSL_DIR=/etc/mysql/ssl
# INIT_DIR=/etc/mysql/init
# PORT="${MYSQL_TLS_PORT:-3306}"

# # Permet de désactiver temporairement TLS obligatoire pour un seeder legacy :
# # ALLOW_INSECURE_FOR_SEED=1 -> --require_secure_transport=OFF
# REQUIRE_SECURE="${ALLOW_INSECURE_FOR_SEED:-0}"

# mkdir -p "$SSL_DIR" "$INIT_DIR"
# cp /ssl-src/ca/ca.crt                    "$SSL_DIR/ca.crt"
# cp /ssl-src/server/mysql_tls/server.crt  "$SSL_DIR/server.crt"
# cp /ssl-src/server/mysql_tls/server.key  "$SSL_DIR/server.key"
# chown -R mysql:mysql "$SSL_DIR" "$INIT_DIR"
# chmod 644 "$SSL_DIR/ca.crt" "$SSL_DIR/server.crt"
# chmod 600 "$SSL_DIR/server.key"

# # SQL idempotent exécuté à CHAQUE démarrage (via --init-file)
# pw_sql=$(printf "%s" "$MYSQL_ROOT_PASSWORD" | sed "s/'/''/g")
# cat > "$INIT_DIR/root_bootstrap.sql" <<EOF
# -- Idempotent: root@% avec mot de passe et privilèges complets
# CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
# ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
# GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
# ALTER USER 'root'@'%' PASSWORD EXPIRE NEVER ACCOUNT UNLOCK;
# FLUSH PRIVILEGES;
# EOF
# chown mysql:mysql "$INIT_DIR/root_bootstrap.sql"
# chmod 600 "$INIT_DIR/root_bootstrap.sql"

# # SQL exécuté uniquement à la toute première init (datadir vierge)
# mkdir -p /docker-entrypoint-initdb.d
# cat > /docker-entrypoint-initdb.d/01_root_tls.sql <<EOF
# CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
# ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${pw_sql}';
# GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
# ALTER USER 'root'@'%' PASSWORD EXPIRE NEVER ACCOUNT UNLOCK;
# FLUSH PRIVILEGES;
# EOF
# chown -R mysql:mysql /docker-entrypoint-initdb.d

# # Drapeau TLS obligatoire
# if [ "$REQUIRE_SECURE" = "1" ]; then
#   # Mode "seed legacy": pas de require_secure_transport
#   RST_FLAG="--require_secure_transport=OFF"
# else
#   RST_FLAG="--require_secure_transport=ON"
# fi

# exec docker-entrypoint.sh mysqld \
#   --port="${PORT}" \
#   --ssl_ca="${SSL_DIR}/ca.crt" \
#   --ssl_cert="${SSL_DIR}/server.crt" \
#   --ssl_key="${SSL_DIR}/server.key" \
#   --tls_version=TLSv1.2,TLSv1.3 \
#   --skip-name-resolve \
#   $RST_FLAG \
#   --init-file="$INIT_DIR/root_bootstrap.sql"
