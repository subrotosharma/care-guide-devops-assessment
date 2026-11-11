import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
)

from app.config import Settings

log = logging.getLogger("app")

# Buckets cover 5ms to 10s; the service itself answers in single-digit ms, so
# the low end matters for p50 and the high end catches stalls.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)

# Paths that fire every few seconds from probes/scrapers. Logged at DEBUG so
# they do not drown out real traffic in Loki.
_QUIET_PATHS = {"/health", "/metrics"}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()

    # A per-app registry (not the global default) keeps tests isolated and
    # avoids exporting the default process/gc collectors twice.
    registry = CollectorRegistry()
    requests_total = Counter(
        "http_requests_total",
        "Total HTTP requests handled.",
        ["method", "path", "status"],
        registry=registry,
    )
    errors_total = Counter(
        "http_request_errors_total",
        "HTTP requests that ended in a 5xx response or an unhandled exception.",
        ["method", "path"],
        registry=registry,
    )
    latency = Histogram(
        "http_request_duration_seconds",
        "HTTP request latency in seconds.",
        ["method", "path"],
        buckets=LATENCY_BUCKETS,
        registry=registry,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        log.info(
            "service starting",
            extra={"version": settings.version, "port": settings.port},
        )
        yield
        # uvicorn stops accepting connections and drains in-flight requests on
        # SIGTERM before this runs, so reaching here means a clean stop.
        log.info("service stopped")

    app = FastAPI(
        title="devops-task",
        version=settings.version,
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.middleware("http")
    async def observe(request: Request, call_next):
        start = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            elapsed = time.perf_counter() - start
            # Use the route template, not the raw URL, so unknown paths cannot
            # blow up label cardinality (every 404 probe would be a new series).
            route = request.scope.get("route")
            path = route.path if route else "unmatched"
            method = request.method

            requests_total.labels(method, path, str(status)).inc()
            latency.labels(method, path).observe(elapsed)
            if status >= 500:
                errors_total.labels(method, path).inc()

            level = logging.DEBUG if request.url.path in _QUIET_PATHS else logging.INFO
            if status >= 500:
                level = logging.ERROR
            log.log(
                level,
                "request handled",
                extra={
                    "method": method,
                    "path": request.url.path,
                    "route": path,
                    "status": status,
                    "duration_ms": round(elapsed * 1000, 2),
                },
            )

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception):
        log.error(
            "unhandled exception",
            exc_info=exc,
            extra={"path": request.url.path, "method": request.method},
        )
        return JSONResponse({"detail": "internal server error"}, status_code=500)

    @app.get("/")
    async def root():
        return {
            "message": "Hello from DevOps Task!",
            "status": "running",
            "version": settings.version,
        }

    @app.get("/health")
    async def health():
        return {"status": "ok", "environment": settings.environment}

    @app.get("/metrics")
    async def metrics():
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    if settings.fault_injection:

        @app.get("/fault")
        async def fault():
            raise RuntimeError("fault injection endpoint hit")

    return app


app = create_app()
