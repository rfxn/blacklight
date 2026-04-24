# blacklight fleet host — Nginx minimal (stack-profile-skip demo target).
# Day 4: add bash + curl + yq so bl-pull/bl-apply run via docker exec.
# No Magento, no PHP — host-3's role is strictly the bl-apply skip beat.
FROM nginx:1.27-alpine

RUN apk add --no-cache bash curl yq

# bl-agent scripts mount via compose volume /opt/bl-agent:ro
RUN mkdir -p /opt/bl-agent /var/bl-agent/reports

EXPOSE 80
