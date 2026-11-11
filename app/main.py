import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

# ---- Configuration (all from environment variables) ----
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
PORT = int(os.getenv("PORT", "8080"))


# ---- Structured JSON logging to stdout ----
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "message": record.getMessage(),
            "environment": ENVIRONMENT,
        }
        # Extra fields attached by the request middleware
        for key in ("method", "path", "status", "duration_ms"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(LOG_LEVEL)


setup_logging()
logger = logging.getLogger("app")

# ---- Prometheus metrics ----
REQUEST_COUNT = Counter(
    "http_requests_total", "Total HTTP requests", ["method", "path", "status"]
)
ERROR_COUNT = Counter(
    "http_errors_total", "Total HTTP 5xx responses", ["method", "path"]
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "path"],
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("service starting", extra={"path": "-"})
    yield
    # Runs after SIGTERM, once in-flight requests have finished
    logger.info("service shutting down gracefully")


app = FastAPI(title="devops-task", version=APP_VERSION, lifespan=lifespan)


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        duration = time.perf_counter() - start
        route = request.scope.get("route")
        # Use the route template (not the raw URL) to keep label cardinality low
        path = route.path if route else "unmatched"
        REQUEST_COUNT.labels(request.method, path, str(status)).inc()
        REQUEST_LATENCY.labels(request.method, path).observe(duration)
        if status >= 500:
            ERROR_COUNT.labels(request.method, path).inc()
        logger.info(
            "request handled",
            extra={
                "method": request.method,
                "path": path,
                "status": status,
                "duration_ms": round(duration * 1000, 2),
            },
        )


@app.get("/")
def root():
    return {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": APP_VERSION,
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    # log_config=None: keep our JSON logging; access_log=False: we log requests ourselves
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_config=None, access_log=False)