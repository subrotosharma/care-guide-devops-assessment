# syntax=docker/dockerfile:1.7
ARG PYTHON_IMAGE=python:3.13.7-alpine3.22

# ---- builder: resolve and install dependencies into an isolated venv --------
FROM ${PYTHON_IMAGE} AS builder
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
RUN python -m venv /opt/venv
# requirements.txt is copied alone so this layer is reused until deps change
COPY requirements.txt .
RUN /opt/venv/bin/pip install -r requirements.txt

# ---- runtime: only the venv and the app code ---------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=0.1.0
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG SOURCE_URL=unknown

LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="Small FastAPI service used for the Care Guide DevOps assessment" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.licenses="MIT"

# The service never needs pip at runtime; removing it shrinks the image and
# takes pip/setuptools CVEs out of the scan surface.
# Pull security fixes (e.g. OpenSSL) that landed after the pinned base image was built.
RUN apk upgrade --no-cache \
    && pip uninstall -y pip setuptools wheel \
    && addgroup -S -g 10001 app \
    && adduser -S -u 10001 -G app -H -s /sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /srv
COPY app ./app

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_PORT=8080 \
    APP_VERSION=${APP_VERSION}

USER 10001:10001
EXPOSE 8080

# Python is already in the image, so no curl/wget needs to be installed
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os,sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ['APP_PORT'], timeout=2).status == 200 else 1)"]

CMD ["python", "-m", "app"]
