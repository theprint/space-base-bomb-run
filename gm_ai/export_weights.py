"""
Export trained GM-AI weights to JSON for embedded GDScript inference.

Usage (from project root):
    python gm_ai/export_weights.py

Output: gm_ai/checkpoints/weights.json  (~500 KB)

After exporting, the Godot game loads this file at startup via
scenes/gm_inference.gd and runs inference without any Python process.
Re-run this script whenever you retrain the model.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import torch
from model   import GMAI, N_FEATURES, N_ACTIONS
from dataset import SEQ_LEN, ACTIONS, NormStats

CKPT_DIR  = os.path.join(os.path.dirname(__file__), "checkpoints")
CKPT_PATH = os.path.join(CKPT_DIR, "best.pt")
NORM_PATH = os.path.join(CKPT_DIR, "norm_stats.json")
OUT_PATH  = os.path.join(CKPT_DIR, "weights.json")

if not os.path.exists(CKPT_PATH):
    raise FileNotFoundError(f"No checkpoint at {CKPT_PATH}. Run train.py first.")
if not os.path.exists(NORM_PATH):
    raise FileNotFoundError(f"No norm stats at {NORM_PATH}. Run train.py first.")

model = GMAI(max_seq=SEQ_LEN)
model.load_state_dict(torch.load(CKPT_PATH, map_location="cpu"))
model.eval()
sd = model.state_dict()

norm = NormStats.load(NORM_PATH)

def flat(key):
    """Return a tensor as a flat Python list, rounded to 6 d.p."""
    return [round(float(v), 6) for v in sd[key].detach().numpy().flatten()]

def rows(key):
    """Return a 2-D tensor as a list-of-rows (for easy per-row lookup)."""
    t = sd[key].detach().numpy()
    return [[round(float(v), 6) for v in row] for row in t]

D  = model.d_model    # 64
NL = 2                # n_layers

out = {
    # Model configuration — GDScript reads these to know array sizes.
    "config": {
        "n_features": N_FEATURES,
        "n_actions":  N_ACTIONS,
        "d_model":    D,
        "n_heads":    4,
        "n_layers":   NL,
        "d_ff":       128,
        "seq_len":    SEQ_LEN,
    },
    "actions":    ACTIONS,
    # Feature normalisation
    "norm_mean":  [round(float(v), 6) for v in norm.mean],
    "norm_std":   [round(float(v), 6) for v in norm.std],
    # Embedding layers (flat 1-D for input_proj, 2-D rows for pos_embed)
    "input_proj_w": flat("input_proj.weight"),   # (D, F) → flat D*F
    "input_proj_b": flat("input_proj.bias"),     # (D,)
    "pos_embed":    rows("pos_embed.weight"),    # (T, D) as list of rows
    # Encoder layers
    "layers": [],
    # Final norm + head
    "final_norm_w": flat("norm.weight"),
    "final_norm_b": flat("norm.bias"),
    "head_w": flat("head.weight"),               # (A, D) → flat A*D
    "head_b": flat("head.bias"),                 # (A,)
}

for i in range(NL):
    p = f"encoder.layers.{i}"
    # PyTorch packs Q/K/V into a single (3D, D) matrix; split it here.
    ipw = sd[f"{p}.self_attn.in_proj_weight"].detach().numpy()
    ipb = sd[f"{p}.self_attn.in_proj_bias"].detach().numpy()
    layer = {
        "q_w": [round(float(v), 6) for v in ipw[:D].flatten()],
        "q_b": [round(float(v), 6) for v in ipb[:D]],
        "k_w": [round(float(v), 6) for v in ipw[D:2*D].flatten()],
        "k_b": [round(float(v), 6) for v in ipb[D:2*D]],
        "v_w": [round(float(v), 6) for v in ipw[2*D:].flatten()],
        "v_b": [round(float(v), 6) for v in ipb[2*D:]],
        "out_w":   flat(f"{p}.self_attn.out_proj.weight"),
        "out_b":   flat(f"{p}.self_attn.out_proj.bias"),
        "norm1_w": flat(f"{p}.norm1.weight"),
        "norm1_b": flat(f"{p}.norm1.bias"),
        "norm2_w": flat(f"{p}.norm2.weight"),
        "norm2_b": flat(f"{p}.norm2.bias"),
        "ff1_w":   flat(f"{p}.linear1.weight"),   # (d_ff, D) → flat
        "ff1_b":   flat(f"{p}.linear1.bias"),
        "ff2_w":   flat(f"{p}.linear2.weight"),   # (D, d_ff) → flat
        "ff2_b":   flat(f"{p}.linear2.bias"),
    }
    out["layers"].append(layer)

with open(OUT_PATH, "w") as f:
    json.dump(out, f, separators=(",", ":"))

size_kb = os.path.getsize(OUT_PATH) / 1024
print(f"Exported {size_kb:.0f} KB → {OUT_PATH}")
print("Copy gm_ai/checkpoints/weights.json into your Godot project before exporting.")
