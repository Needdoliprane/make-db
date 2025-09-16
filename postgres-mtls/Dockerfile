FROM postgres:16-alpine

# On dépose le script d’init qui va activer TLS + mTLS
COPY 01-enable-ssl.sh /docker-entrypoint-initdb.d/01-enable-ssl.sh
RUN chmod +x /docker-entrypoint-initdb.d/01-enable-ssl.sh

# Par défaut ce profil force mTLS
ENV REQUIRE_CLIENT_CERT=1
ENV CERT_PROFILE=pg_mtls

EXPOSE 5432
