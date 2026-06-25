from __future__ import annotations

from types import SimpleNamespace

import torch

from opf._api import _redact_text
from opf._core.runtime import PredictionResult
from opf._core.sequence_labeling import LabelInfo

from privacy_filter_service.fast_predict import predict_text_gpu_decode, redact_with_gpu_decode


class _OneTokenEncoding:
    def __init__(self, decoded: bytes = b"A") -> None:
        self.decoded = decoded

    def encode(self, text: str, allowed_special: str = "all") -> list[int]:
        return [1]

    def decode_single_token_bytes(self, token_id: int) -> bytes:
        return self.decoded


class _SingleSpanModel:
    def __call__(self, tokens: torch.Tensor, attention_mask: torch.Tensor | None = None) -> torch.Tensor:
        logits = torch.full((1, 1, 5), -1000.0, device=tokens.device)
        logits[0, 0, 4] = 1000.0  # S-private_email
        return logits


def _label_info() -> LabelInfo:
    return LabelInfo(
        boundary_label_lookup={"private_email": {"B": 1, "I": 2, "E": 3, "S": 4}},
        token_to_span_label={0: 0, 1: 1, 2: 1, 3: 1, 4: 1},
        token_boundary_tags={0: None, 1: "B", 2: "I", 3: "E", 4: "S"},
        span_class_names=("O", "private_email"),
        span_label_lookup={"O": 0, "private_email": 1},
        background_token_label=0,
        background_span_label=0,
    )


def _runtime(output_mode: str = "typed", decoded: bytes = b"A") -> SimpleNamespace:
    return SimpleNamespace(
        encoding=_OneTokenEncoding(decoded=decoded),
        label_info=_label_info(),
        device=torch.device("cpu"),
        n_ctx=16,
        model=_SingleSpanModel(),
        trim_span_whitespace=True,
        discard_overlapping_predicted_spans=False,
        output_mode=output_mode,
    )


def test_predict_text_gpu_decode_applies_redacted_output_mode() -> None:
    prediction = predict_text_gpu_decode(_runtime(output_mode="redacted"), "A", decoder=None)

    assert [(span.label, span.placeholder, span.text) for span in prediction.spans] == [
        ("redacted", "<REDACTED>", "A")
    ]
    assert _redact_text(prediction.text, prediction.spans) == "<REDACTED>"


def test_redact_with_gpu_decode_preserves_decoded_mismatch_warning(monkeypatch) -> None:
    runtime = _runtime()

    class FakeOPF:
        _output_text_only = False

        def get_prediction_components(self):
            return runtime, None

    def fake_predict_text_gpu_decode(runtime, text, *, decoder):
        return PredictionResult(text="A", spans=(), decoded_mismatch=True)

    monkeypatch.setattr(
        "privacy_filter_service.fast_predict.predict_text_gpu_decode",
        fake_predict_text_gpu_decode,
    )

    result = redact_with_gpu_decode(FakeOPF(), "A")

    assert result.warning == (
        "Input text did not exactly match tokenizer round-trip decode; spans are based on "
        "decoded token text."
    )
