# tests/Dockerfile — blacklight test image
# Layers blacklight runtime deps on the batsman base image.
# Base already provides: bash coreutils findutils diffutils procps gawk sed grep gzip tar wget curl ca-certificates util-linux hostname parallel bats-core.
# Missing and required by blacklight: jq zstd shellcheck.
ARG BASE_IMAGE=blacklight-base-debian12
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    jq zstd shellcheck patch cron \
    apache2 libapache2-mod-security2 iptables nftables yara whois \
    && rm -rf /var/lib/apt/lists/*

# M6: mock LMD (maldet) + ClamAV (clamscan/clamdscan) shims so bl_defend_sig
# can detect + invoke scanners without installing real binaries (~400MB).
RUN mkdir -p /usr/local/maldetect && \
    printf '#!/bin/bash\necho "maldet shim: ${*}"; exit 0\n' \
        > /usr/local/maldetect/maldet && \
    chmod +x /usr/local/maldetect/maldet && \
    printf '#!/bin/bash\necho "clamscan shim: ${*}"; exit 0\n' \
        > /usr/local/bin/clamscan && \
    printf '#!/bin/bash\necho "clamdscan shim: ${*}"; exit 0\n' \
        > /usr/local/bin/clamdscan && \
    chmod +x /usr/local/bin/clamscan /usr/local/bin/clamdscan

# M6: FP-corpus sample directory (real system path bl_defend_sig reads).
COPY tests/fixtures/defend-fp-corpus/ /var/lib/bl/fp-corpus/

# Project source at /opt/blacklight-src (reference); test files at /opt/tests/
# (matches BATSMAN_CONTAINER_TEST_PATH); `bl` at /opt/bl so that tests resolving
# $BATS_TEST_DIRNAME/../bl from /opt/tests find it at /opt/bl.
# schemas/, prompts/, case-templates/ alongside bl so repo_root=/opt resolves them.
# prompts/ is required by M8 bl_setup_compose_agent_body (reads prompts/curator-agent.md).
COPY . /opt/blacklight-src
COPY tests/ /opt/tests/
COPY bl /opt/bl
COPY install.sh /opt/install.sh
COPY uninstall.sh /opt/uninstall.sh
COPY schemas/ /opt/schemas/
COPY prompts/ /opt/prompts/
COPY case-templates/ /opt/case-templates/
COPY skills/ /opt/skills/
COPY scripts/ /opt/scripts/
COPY tools/ /opt/tools/
RUN chmod +x /opt/bl /opt/tools/dev/synth-corpus.sh

WORKDIR /opt/tests
