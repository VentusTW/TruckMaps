# Java dla Photon + zstd do rozpakowania zrzutu w kontenerze (infra/photon_import.ps1).
FROM eclipse-temurin:21-jre
RUN apt-get update \
    && apt-get install -y --no-install-recommends zstd \
    && rm -rf /var/lib/apt/lists/*
