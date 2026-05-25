"""
GM-AI Transformer model.

Input:  (batch, seq_len, N_FEATURES)  — sequence of game-state snapshots
Output: (batch, N_ACTIONS)            — action weight distribution (sums to 1)
"""

import torch
import torch.nn as nn
import torch.nn.functional as F

N_FEATURES = 20
N_ACTIONS  = 13
D_MODEL    = 64
N_HEADS    = 4
N_LAYERS   = 2
D_FF       = 128
DROPOUT    = 0.3


class GMAI(nn.Module):
    def __init__(
        self,
        n_features: int = N_FEATURES,
        n_actions:  int = N_ACTIONS,
        d_model:    int = D_MODEL,
        nhead:      int = N_HEADS,
        num_layers: int = N_LAYERS,
        d_ff:       int = D_FF,
        dropout:    float = DROPOUT,
        max_seq:    int = 16,
    ):
        super().__init__()
        self.d_model = d_model
        self.max_seq = max_seq

        self.input_proj = nn.Linear(n_features, d_model)
        self.pos_embed  = nn.Embedding(max_seq, d_model)

        encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=nhead,
            dim_feedforward=d_ff,
            dropout=dropout,
            batch_first=True,
        )
        self.encoder = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)
        self.norm    = nn.LayerNorm(d_model)
        self.head    = nn.Linear(d_model, n_actions)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        x: (B, T, F)
        Returns: (B, N_ACTIONS) — softmax probability distribution
        """
        B, T, _ = x.shape
        pos = torch.arange(T, device=x.device).unsqueeze(0)   # (1, T)
        h = self.input_proj(x) + self.pos_embed(pos)          # (B, T, D)
        h = self.encoder(h)                                    # (B, T, D)
        h = self.norm(h[:, -1, :])                            # last token (B, D)
        return F.softmax(self.head(h), dim=-1)                 # (B, A)
