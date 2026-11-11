"""Runtime configuration, read once from environment variables."""

import os
from dataclasses import dataclass

_VALID_LOG_LEVELS = {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}


def _env_bool(name: str, default: bool = False) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    port: int
    log_level: str
    environment: str
    version: str
    # Lets us trigger 5xx responses on demand to exercise the error-rate alert
    # and the troubleshooting walkthrough. Off unless explicitly enabled.
    fault_injection: bool

    @classmethod
    def from_env(cls) -> "Settings":
        raw_port = os.getenv("APP_PORT", "8080")
        try:
            port = int(raw_port)
        except ValueError as exc:
            raise ValueError(f"APP_PORT must be an integer, got {raw_port!r}") from exc
        if not 1 <= port <= 65535:
            raise ValueError(f"APP_PORT out of range: {port}")

        log_level = os.getenv("LOG_LEVEL", "INFO").upper()
        if log_level not in _VALID_LOG_LEVELS:
            raise ValueError(
                f"LOG_LEVEL must be one of {sorted(_VALID_LOG_LEVELS)}, got {log_level!r}"
            )

        return cls(
            port=port,
            log_level=log_level,
            environment=os.getenv("APP_ENV", "local"),
            version=os.getenv("APP_VERSION", "0.1.0"),
            fault_injection=_env_bool("ENABLE_FAULT_INJECTION"),
        )
