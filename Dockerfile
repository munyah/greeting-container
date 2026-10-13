# syntax=docker/dockerfile:1

# python:3.12-slim, use a smaller base image
ARG PYTHON_IMAGE=python@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

# ---- Build stage: resolve dependencies into an isolated virtualenv ----
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy only the requirements first so the dependency layer is cached
# independently of application source changes.
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install --require-virtualenv -r /tmp/requirements.txt

# ---- Runtime stage: minimal image, no build tooling, non-root ----
FROM ${PYTHON_IMAGE} AS runtime

#always a good idea to have some metadata
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown

LABEL org.opencontainers.image.title="dwp-greeting-app" \
      org.opencontainers.image.description="Minimal Flask greeting service served by gunicorn" \
      org.opencontainers.image.source="https://github.com/dwp/greeting-container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080 \
    WEB_CONCURRENCY=2

# Create a non-root user and group.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
# Only the application code; root-owned so the runtime user cannot modify it.
COPY app/app.py ./

USER 10001:10001

EXPOSE 8080

# Uses the bundled Python interpreter, so no curl/wget is needed in the image.
# HEALTHCHECK CMD curl --fail http://localhost:8000 || exit 1
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen(f\"http://127.0.0.1:{os.environ.get('PORT', '8080')}/healthz\", timeout=2)"]

# Exec form so gunicorn is PID 1 and receives SIGTERM for graceful shutdown.
# gunicorn binds to 0.0.0.0:$PORT and reads its worker count from
# $WEB_CONCURRENCY by default; further flags can be passed via GUNICORN_CMD_ARGS.
CMD ["gunicorn", "--access-logfile", "-", "--worker-tmp-dir", "/dev/shm", "app:app"]
