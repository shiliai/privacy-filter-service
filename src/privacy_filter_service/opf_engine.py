"""Async singleton wrapper for the local OPF redaction engine."""

# pyright: reportMissingTypeStubs=false

from __future__ import annotations

import asyncio
from typing import Annotated, Literal

from fastapi import Depends
from opf._api import OPF, RedactionResult as OPFRedactionResult

from privacy_filter_service.config import ServiceConfig, Settings, load_settings
from privacy_filter_service.models import RedactionResult


class OPFEngine:
    """Serialize access to a single OPF instance."""

    def __init__(self, service_settings: ServiceConfig) -> None:
        self.device: Literal["cuda", "cpu"] = service_settings.device
        self.output_mode: Literal["typed", "redacted"] = service_settings.output_mode
        self.decode_mode: Literal["viterbi", "argmax"] = service_settings.decode_mode
        self.model_path: str = service_settings.model_path
        self.ready: bool = False
        self._opf: OPF | None = None
        self._lock: asyncio.Lock = asyncio.Lock()

    @property
    def lock(self) -> asyncio.Lock:
        return self._lock

    async def warmup(self) -> None:
        """Instantiate OPF once and verify the configured device works."""
        async with self._lock:
            if self.ready:
                return
            self._validate_device()
            opf = OPF(
                model=self.model_path,
                device=self.device,
                output_mode=self.output_mode,
                decode_mode=self.decode_mode,
            )
            smoke: str | OPFRedactionResult = opf.redact("test")
            if isinstance(smoke, str):
                raise TypeError("OPF.redact() returned text-only output during warmup")
            self._opf = opf
            self.ready = True

    async def redact(self, text: str) -> RedactionResult:
        await self.warmup()
        async with self._lock:
            opf = self._require_opf()
            result: str | OPFRedactionResult = opf.redact(text)
            if isinstance(result, str):
                raise TypeError("OPF.redact() returned text-only output")
            return RedactionResult.model_validate(result.to_dict())

    async def redact_batch(self, texts: list[str]) -> list[RedactionResult]:
        await self.warmup()
        async with self._lock:
            opf = self._require_opf()
            results: list[RedactionResult] = []
            for text in texts:
                result: str | OPFRedactionResult = opf.redact(text)
                if isinstance(result, str):
                    raise TypeError("OPF.redact() returned text-only output")
                results.append(RedactionResult.model_validate(result.to_dict()))
            return results

    def _require_opf(self) -> OPF:
        if self._opf is None:
            raise RuntimeError("OPF engine not initialized")
        return self._opf

    def _validate_device(self) -> None:
        if self.device != "cuda":
            return
        import torch

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA requested for OPFEngine, but torch.cuda.is_available() is False")


_engine: OPFEngine | None = None


async def get_engine(settings: Annotated[Settings, Depends(load_settings)]) -> OPFEngine:
    """Return the singleton engine instance, warming it lazily on first use."""
    global _engine
    if _engine is None:
        _engine = OPFEngine(settings.service)
    if not _engine.ready:
        await _engine.warmup()
    return _engine
