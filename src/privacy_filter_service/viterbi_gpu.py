"""JIT-compiled GPU Viterbi CRF decoder.

Eliminates the Python for-loop overhead in OPF's decode_many by using
@torch.jit.script to compile the entire forward scan + backtracking into
a single TorchScript graph that runs entirely on GPU.
"""

from __future__ import annotations

import torch
from torch import Tensor


def viterbi_decode_scan(
    emissions: Tensor,
    transitions: Tensor,
    start_transitions: Tensor,
    end_transitions: Tensor,
) -> Tensor:
    """Batched Viterbi decode on GPU.

    Args:
        emissions: (B, T, C) log-probabilities per token per class.
        transitions: (C, C) transition scores.
        start_transitions: (C,) start scores.
        end_transitions: (C,) end scores.

    Returns:
        (B, T) LongTensor of best label indices.
    """
    return _viterbi_decode_jit(emissions, transitions, start_transitions, end_transitions)


@torch.jit.script
def _viterbi_decode_jit(
    emissions: Tensor,
    transitions: Tensor,
    start_transitions: Tensor,
    end_transitions: Tensor,
) -> Tensor:
    batch_size = emissions.size(0)
    seq_len = emissions.size(1)
    num_classes = emissions.size(2)

    # scores: (B, C) — best score to reach each class at current step
    scores = emissions[:, 0, :] + start_transitions.unsqueeze(0)

    # backpointers: (B, T-1, C) — which previous class gave the best score
    backpointers = torch.zeros(
        batch_size, seq_len - 1, num_classes, dtype=torch.long, device=emissions.device
    )

    for t in range(1, seq_len):
        # transitions: (B, C, C) = scores[:, :, None] + transitions[None, :, :]
        # We want max over previous class (dim 1), giving (B, C)
        prev_scores = scores.unsqueeze(2)  # (B, C, 1)
        trans_scores = transitions.unsqueeze(0)  # (1, C, C)
        all_scores = prev_scores + trans_scores  # (B, C, C)
        best_scores, best_paths = torch.max(all_scores, dim=1)  # (B, C), (B, C)
        scores = best_scores + emissions[:, t, :]
        backpointers[:, t - 1, :] = best_paths

    # Add end scores
    scores = scores + end_transitions.unsqueeze(0)

    # Backtrack
    last_labels = torch.argmax(scores, dim=1)  # (B,)
    paths = torch.zeros(batch_size, seq_len, dtype=torch.long, device=emissions.device)
    paths[:, seq_len - 1] = last_labels

    for t in range(seq_len - 2, -1, -1):
        # Gather backpointers for each batch
        # backpointers[:, t, last_labels] -> (B,)
        prev_labels = torch.gather(
            backpointers[:, t, :], 1, last_labels.unsqueeze(1)
        ).squeeze(1)
        paths[:, t] = prev_labels
        last_labels = prev_labels

    return paths
