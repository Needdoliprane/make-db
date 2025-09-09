FROM postgres:16
COPY 01-enable-ssl.sh /docker-entrypoint-initdb.d/01-enable-ssl.sh
RUN chmod +x /docker-entrypoint-initdb.d/01-enable-ssl.sh
