# tlsproxy/Dockerfile
FROM debian:bookworm-slim

# Outils nécessaires
RUN apt-get update && apt-get install -y --no-install-recommends \
    stunnel4 openssl ca-certificates \
    softhsm2 opensc p11-kit \
    libengine-pkcs11-openssl \
    dpkg-dev \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Chemins de config par défaut
ENV OPENSSL_CONF=/etc/ssl/openssl-pkcs11.cnf \
    SOFTHSM2_CONF=/etc/softhsm2.conf

# Génère openssl-pkcs11.cnf (OpenSSL 3) en s’adaptant à l’architecture
RUN set -eux; \
    arch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    mkdir -p /etc/ssl; \
    cat > /etc/ssl/openssl-pkcs11.cnf <<EOF
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[engine_section]
pkcs11 = pkcs11_section

[pkcs11_section]
engine_id   = pkcs11
dynamic_path = /usr/lib/${arch}/engines-3/pkcs11.so
MODULE_PATH  = /usr/lib/softhsm/libsofthsm2.so
init         = 1
EOF

# Génère un SOFTHSM2_CONF par défaut (sera recréé à l’entrypoint si besoin)
RUN cat > /etc/softhsm2.conf <<'EOF'
directories.tokendir = /var/lib/softhsm/tokens
objectstore.backend  = file
slots.removable      = true
EOF

# Scripts & template
COPY --chmod=0755 docker-entrypoint.sh /docker-entrypoint.sh

COPY stunnel.conf.template /stunnel.conf.template
RUN sed -i 's/\r$//' /docker-entrypoint.sh \
    && head -c 2 /docker-entrypoint.sh | od -An -t x1 | grep -qi '23 21' || true


ENTRYPOINT ["/docker-entrypoint.sh"]
