# tests/Dockerfile — blacklight test image
# Layers blacklight runtime deps on the batsman base image.
# Base already provides: bash coreutils findutils diffutils procps gawk sed grep gzip tar wget curl ca-certificates util-linux hostname parallel bats-core.
# Missing and required by blacklight: jq zstd shellcheck.
ARG BASE_IMAGE=blacklight-base-debian12
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq zstd shellcheck patch cron \
    && rm -rf /var/lib/apt/lists/*

# Project source at /opt/blacklight-src (reference); test files at /opt/tests/
# (matches BATSMAN_CONTAINER_TEST_PATH); `bl` at /opt/bl so that tests resolving
# $BATS_TEST_DIRNAME/../bl from /opt/tests find it at /opt/bl.
# schemas/ and case-templates/ alongside bl so repo_root=/opt resolves them.
COPY . /opt/blacklight-src
COPY tests/ /opt/tests/
COPY bl /opt/bl
COPY schemas/ /opt/schemas/
COPY case-templates/ /opt/case-templates/
RUN chmod +x /opt/bl

WORKDIR /opt/tests
