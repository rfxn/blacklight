# blacklight fleet host — Apache + PHP base.
# Day 1 scope: a working web host reachable on the fleet bridge network.
# Day 2+: layer Magento 2.4.x, mod_security, staged PolyShell exhibit.
#   ModSec layer and Magento image choice are TODO-operator (ASK before
#   locking; HANDOFF §Day-1-step-5 requires realism check on staged artifact).
FROM php:8.3-apache

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates libapache2-mod-security2 \
 && rm -rf /var/lib/apt/lists/* \
 && a2enmod rewrite headers security2 unique_id \
 && curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq

# bl-agent scripts mount in via compose volume (/opt/bl-agent).
# Day 2+: install.sh wires these into systemd. Day 1 just holds the dir.
RUN mkdir -p /opt/bl-agent /var/bl-agent/reports

EXPOSE 80
