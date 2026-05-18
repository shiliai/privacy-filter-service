"""Pydantic-based configuration loader with TOML + env-var overlay."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Literal

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore[no-redef]

from pydantic import BaseModel, Field, ValidationError

OPF_CHECKPOINT_ENV = "OPF_CHECKPOINT"
PRIVACY_FILTER_CONFIG_ENV = "PRIVACY_FILTER_CONFIG"

_ENV_OVERRIDES: dict[str, str] = {
    "PRIVACY_FILTER_LISTEN_HOST": "service.host",
    "PRIVACY_FILTER_LISTEN_PORT": "service.port",
    "PRIVACY_FILTER_DEVICE": "service.device",
    "PRIVACY_FILTER_OUTPUT_MODE": "service.output_mode",
    "PRIVACY_FILTER_DECODE_MODE": "service.decode_mode",
    "PRIVACY_FILTER_MODEL_PATH": "service.model_path",
    "PRIVACY_FILTER_LOG_LEVEL": "service.log_level",
    "PRIVACY_FILTER_URL": "hook.base_url",
    "PRIVACY_FILTER_TIMEOUT_S": "hook.request_timeout_s",
    "PRIVACY_FILTER_MAX_FILE_BYTES": "hook.max_file_bytes",
    "PRIVACY_FILTER_MAX_INFLIGHT_WARNS": "hook.max_inflight_warns_per_5min",
}


def _deep_set(data: dict, dotted: str, value: object) -> None:
    parts = dotted.split(".")
    current = data
    for part in parts[:-1]:
        current = current.setdefault(part, {})
    current[parts[-1]] = value


def _apply_env_overlays(raw: dict) -> dict:
    for env_var, dotted_key in _ENV_OVERRIDES.items():
        val = os.environ.get(env_var)
        if val is None:
            continue
        if dotted_key in (
            "service.port",
            "hook.request_timeout_s",
            "hook.max_file_bytes",
            "hook.max_inflight_warns_per_5min",
        ):
            try:
                val = int(val)  # type: ignore[assignment]
            except ValueError:
                try:
                    val = float(val)  # type: ignore[assignment]
                except ValueError:
                    pass
        _deep_set(raw, dotted_key, val)
    return raw


class ServiceConfig(BaseModel):
    """Configuration for the privacy-filter inference service."""

    host: str = "0.0.0.0"
    port: int = Field(default=8765, ge=1, le=65535)
    device: Literal["cuda", "cpu"] = "cuda"
    output_mode: Literal["typed", "redacted"] = "typed"
    decode_mode: Literal["viterbi", "argmax"] = "viterbi"
    model_path: str
    log_level: str = "INFO"


class HookConfig(BaseModel):
    """Configuration for the Git pre-receive hook client."""

    base_url: str = "http://127.0.0.1:8765"
    request_timeout_s: float = Field(default=5.0, ge=1, le=60)
    max_file_bytes: int = Field(default=262144, le=1_048_576)
    max_inflight_warns_per_5min: int = 1


class Settings(BaseModel):
    """Top-level application settings."""

    service: ServiceConfig
    hook: HookConfig = Field(default_factory=HookConfig)


def load_settings(
    config_path: str | Path | None = None,
    config_text: str | None = None,
) -> Settings:
    """Load TOML config, overlay env vars, validate, and return Settings.

    Resolution order (later wins):
      1. TOML file (~/.config/privacy-filter/config.toml or PRIVACY_FILTER_CONFIG)
      2. PRIVACY_FILTER_* env var overrides
      3. OPF_CHECKPOINT env → service.model_path (only if TOML didn't set it)

    Crashes with SystemExit on invalid or missing config.
    """
    if config_text is not None:
        raw: dict = tomllib.loads(config_text)
    else:
        if config_path is None:
            config_path = os.environ.get(
                PRIVACY_FILTER_CONFIG_ENV,
                Path.home() / ".config" / "privacy-filter" / "config.toml",
            )
        config_path = Path(config_path)
        if not config_path.is_file():
            print(
                f"[FATAL] Config file not found: {config_path}",
                file=sys.stderr,
            )
            sys.exit(1)
        raw = tomllib.loads(config_path.read_text(encoding="utf-8"))

    raw = _apply_env_overlays(raw)

    svc = raw.setdefault("service", {})
    if "model_path" not in svc:
        checkpoint = os.environ.get(OPF_CHECKPOINT_ENV)
        if checkpoint:
            svc["model_path"] = checkpoint

    try:
        return Settings.model_validate(raw)
    except ValidationError as exc:
        print("[FATAL] Invalid configuration:", file=sys.stderr)
        print(exc, file=sys.stderr)
        sys.exit(1)
