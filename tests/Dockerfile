# tests/Dockerfile — blacklight test image
# Layers blacklight runtime deps on the batsman base image.
ARG BASE_IMAGE=blacklight-base-debian12
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq awk sed tar gzip zstd coreutils shellcheck \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/blacklight-src
