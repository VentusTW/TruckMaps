# Narzedzie osmium (laczenie i przycinanie map OSM) - dla infra/merge_maps.ps1.
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends osmium-tool \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /data
ENTRYPOINT ["osmium"]
