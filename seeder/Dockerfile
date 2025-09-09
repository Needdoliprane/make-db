FROM python:3.11-slim

# Certs systèmes pour la vérif TLS
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY seeder.py /app/seeder.py

ENTRYPOINT ["python", "/app/seeder.py"]
