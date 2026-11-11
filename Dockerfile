# syntax=docker/dockerfile:1

# ---------- Stage 1: install dependencies ----------
FROM python:3.12.16-alpine3.24 AS builder
WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Stage 2: minimal runtime image ----------
FROM python:3.12.16-alpine3.24

ARG APP_VERSION=0.1.0

LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="Small FastAPI service for the DevOps assessment" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080

# Non-root user with a fixed numeric UID (Kubernetes runAsNonRoot needs a numeric UID)
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

WORKDIR /srv
COPY --from=builder /install /usr/local
COPY app ./app

USER 10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-m", "app.healthcheck"]

CMD ["python", "-m", "app.main"]
