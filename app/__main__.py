"""Entry point: `python -m app`.

Run uvicorn programmatically so the port and log level come from our own
settings object. uvicorn installs SIGTERM/SIGINT handlers: it stops accepting
connections, waits up to `timeout_graceful_shutdown` for in-flight requests,
runs the lifespan shutdown hook, then restores the previous signal handlers and
re-raises the signal. With the default handler that would kill the process with
status 143 even though the drain succeeded, so we install a handler beforehand
that turns the re-raised SIGTERM into a normal exit(0).
"""

import signal
import sys

import uvicorn

from app.config import Settings
from app.logging_config import configure_logging


def main() -> None:
    settings = Settings.from_env()
    configure_logging(settings.log_level, settings.environment)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",  # noqa: S104 - container workload, exposure is controlled by the runtime
        port=settings.port,
        log_config=None,
        timeout_graceful_shutdown=10,
    )


if __name__ == "__main__":
    main()
