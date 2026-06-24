"""GPU-friendly replacement for OPF's predict_text.

The upstream ``opf._core.runtime.predict_text`` moves per-token log-probs back
 to the CPU immediately and then runs the Viterbi CRF decoder in a Python
 loop. For long texts this dominates latency (>15 s for ~20k chars) even
 though the model forward pass on GPU only takes ~100 ms.

This module provides ``predict_text_gpu_decode`` which keeps the token score
 tensors on the same device as the model and uses
 ``ViterbiCRFDecoder.decode_many(..., device=cuda_device)`` so the decoder
 runs batched on GPU.
"""

from __future__ import annotations

import math
from typing import TYPE_CHECKING

import torch
import torch.nn.functional as F

from opf._api import _redact_text
from opf._core.decoding import ViterbiCRFDecoder
from opf._core.runtime import (
    DetectedSpan,
    InferenceRuntime,
    PredictionResult,
    build_detection_summary,
)
from opf._core.sequence_labeling import (
    ExampleAggregation,
    TokenizedExample,
    example_to_windows,
)
from opf._core.spans import (
    decode_text_with_offsets,
    discard_overlapping_spans_by_label,
    labels_to_spans,
    token_spans_to_char_spans,
    trim_char_spans_whitespace,
)

if TYPE_CHECKING:
    from opf._api import OPF


@torch.inference_mode()
def predict_text_gpu_decode(
    runtime: InferenceRuntime,
    text: str,
    *,
    decoder: ViterbiCRFDecoder | None,
) -> PredictionResult:
    """Run one text through the model and decode on the model's device.

    This mirrors ``opf._core.runtime.predict_text`` except that log-probs are
    kept on ``runtime.device`` and Viterbi decoding uses the batched CUDA
    path when a GPU is available.
    """
    token_ids = tuple(
        int(tok) for tok in runtime.encoding.encode(text, allowed_special="all")
    )
    if not token_ids:
        return PredictionResult(text=text, spans=(), decoded_mismatch=False)

    example_id = "demo-example"
    background = int(runtime.label_info.background_token_label)
    example = TokenizedExample(
        tokens=token_ids,
        labels=tuple(background for _ in token_ids),
        example_id=example_id,
        text=text,
    )

    aggregation = ExampleAggregation(
        logprob_logsumexp=[], counts=[], labels=[], token_ids=[]
    )

    for window in example_to_windows(example, runtime.n_ctx):
        if not window.tokens:
            continue
        window_tokens = torch.tensor(
            [list(window.tokens)],
            device=runtime.device,
            dtype=torch.int32,
        )
        attention_mask = torch.ones_like(window_tokens, dtype=torch.bool)
        logits = runtime.model(window_tokens, attention_mask=attention_mask)
        # Keep log-probs on the model device instead of moving to CPU.
        log_probs = F.log_softmax(logits.float(), dim=-1)[0]
        if log_probs.shape[0] != len(window.tokens):
            raise ValueError("Logprob output length does not match window length")

        for token_pos, is_valid in enumerate(window.mask):
            if not bool(is_valid):
                continue
            token_idx = int(window.offsets[token_pos])
            if token_idx < 0:
                continue
            aggregation.ensure_capacity(token_idx)
            score_vec = log_probs[token_pos]
            existing = aggregation.logprob_logsumexp[token_idx]
            if existing is None:
                aggregation.logprob_logsumexp[token_idx] = score_vec.clone()
            else:
                aggregation.logprob_logsumexp[token_idx] = torch.logaddexp(
                    existing, score_vec
                )
            aggregation.counts[token_idx] += 1
            aggregation.record_token_id(
                token_idx, int(window.tokens[token_pos]), example_id
            )
            aggregation.length = max(aggregation.length, token_idx + 1)

    token_positions: list[int] = []
    token_score_vectors: list[torch.Tensor] = []
    for token_idx in range(aggregation.length):
        if token_idx >= len(aggregation.logprob_logsumexp):
            continue
        score_sum = aggregation.logprob_logsumexp[token_idx]
        count = aggregation.counts[token_idx]
        if score_sum is None or count <= 0:
            continue
        avg_logprob = score_sum - math.log(float(count))
        token_positions.append(token_idx)
        token_score_vectors.append(avg_logprob)

    if not token_score_vectors:
        return PredictionResult(text=text, spans=(), decoded_mismatch=False)

    stacked_scores = torch.stack(token_score_vectors, dim=0)
    if decoder is not None:
        # Use the batched CUDA decoder path when possible.
        decoded_labels = decoder.decode_many(
            [stacked_scores], device=runtime.device
        )[0]
        if len(decoded_labels) != len(token_positions):
            decoded_labels = stacked_scores.argmax(dim=1).tolist()
    else:
        decoded_labels = stacked_scores.argmax(dim=1).tolist()

    predicted_labels_by_index = {
        token_idx: int(label)
        for token_idx, label in zip(token_positions, decoded_labels)
    }
    predicted_token_spans = labels_to_spans(
        predicted_labels_by_index, runtime.label_info
    )

    decoded_text, char_starts, char_ends = decode_text_with_offsets(
        token_ids, runtime.encoding
    )
    decoded_mismatch = decoded_text != text
    source_text = decoded_text if decoded_mismatch else text

    predicted_char_spans = token_spans_to_char_spans(
        predicted_token_spans, char_starts, char_ends
    )
    if runtime.trim_span_whitespace:
        predicted_char_spans = trim_char_spans_whitespace(
            predicted_char_spans, source_text
        )
    if runtime.discard_overlapping_predicted_spans:
        predicted_char_spans = discard_overlapping_spans_by_label(
            predicted_char_spans
        )

    detected: list[DetectedSpan] = []
    for label_idx, start, end in predicted_char_spans:
        if not (0 <= start < end <= len(source_text)):
            continue
        label = (
            str(runtime.label_info.span_class_names[label_idx])
            if 0 <= int(label_idx) < len(runtime.label_info.span_class_names)
            else f"label_{label_idx}"
        )
        normalized = "".join(
            ch if ch.isalnum() else "_" for ch in label.upper()
        ).strip("_")
        if not normalized:
            normalized = "REDACTED"
        placeholder = f"<{normalized}>"
        detected.append(
            DetectedSpan(
                label=label,
                start=int(start),
                end=int(end),
                text=source_text[start:end],
                placeholder=placeholder,
            )
        )

    display_spans = _select_non_overlapping_spans(detected)
    return PredictionResult(
        text=source_text,
        spans=tuple(display_spans),
        decoded_mismatch=decoded_mismatch,
    )


def _select_non_overlapping_spans(spans: list[DetectedSpan]) -> list[DetectedSpan]:
    """Keep a left-to-right non-overlapping subset of detected spans."""
    ordered = sorted(
        spans, key=lambda span: (span.start, -(span.end - span.start), span.label)
    )
    kept: list[DetectedSpan] = []
    cursor = 0
    for span in ordered:
        if span.start < cursor:
            continue
        if span.end <= span.start:
            continue
        kept.append(span)
        cursor = span.end
    return kept


def redact_with_gpu_decode(opf: "OPF", text: str) -> "str | opf._api.RedactionResult":
    """Run OPF redaction using the GPU-resident prediction path.

    This bypasses ``OPF.redact`` so we can inject ``predict_text_gpu_decode``.
    """
    from opf._api import RedactionResult as OPFRedactionResult

    runtime, decoder = opf.get_prediction_components()
    prediction = predict_text_gpu_decode(runtime, text, decoder=decoder)
    redacted_text = _redact_text(prediction.text, prediction.spans)
    if opf._output_text_only:
        return redacted_text
    summary = build_detection_summary(
        output_mode=runtime.output_mode,
        labels=[span.label for span in prediction.spans],
        decoded_mismatch=prediction.decoded_mismatch,
    )
    return OPFRedactionResult(
        schema_version=1,
        summary=summary,
        text=prediction.text,
        detected_spans=prediction.spans,
        redacted_text=redacted_text,
        warning=None,
    )
