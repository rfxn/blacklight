# blacklight curator — local Flask glue (manifest HTTP + report inbox).
# Claude-driven work runs in a Managed Agents session, not in this container.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      curl \
      apache2 apache2-utils libapache2-mod-security2 \
 && rm -rf /var/lib/apt/lists/*

COPY curator /app/curator
COPY prompts /app/prompts
COPY demo /app/demo
COPY tests/fixtures/sim /app/sim_tars

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    BL_STORAGE=/app/curator/storage \
    BL_INBOX=/app/inbox \
    BL_SIM_TARS_DIR=/app/sim_tars

EXPOSE 8080

CMD ["python", "-m", "curator.server"]
