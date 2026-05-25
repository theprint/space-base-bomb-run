"""
GM-AI inference server.

Loads the trained model and serves action-weight predictions over HTTP so the
Godot game can call it without any native ML dependencies.

Usage:
    python gm_ai/serve.py

Endpoint:
    POST http://localhost:5001/predict
    Body: {"snapshots": [[f0, f1, ..., f19], ...]}   ← up to SEQ_LEN rows
    Returns: {"actions": {"hold": 0.12, "budget_increase": 0.08, ...}}

The game sends its rolling buffer of recent snapshots (oldest first).
Fewer than SEQ_LEN snapshots are zero-padded on the left automatically.
"""

import os
import json
import numpy as np
import torch
from flask import Flask, request, jsonify

# Add parent dir so imports work when run from any cwd
import sys
sys.path.insert(0, os.path.dirname(__file__))

from model   import GMAI
from model   import N_FEATURES
from dataset import NormStats, ACTIONS, SEQ_LEN

# ── Config ───────────────────────────────────────────────────────────────────

CKPT_DIR  = os.path.join(os.path.dirname(__file__), "checkpoints")
CKPT_PATH = os.path.join(CKPT_DIR, "best.pt")
NORM_PATH = os.path.join(CKPT_DIR, "norm_stats.json")
PORT      = 5001

# ── Load model ────────────────────────────────────────────────────────────────

if not os.path.exists(CKPT_PATH):
    raise FileNotFoundError(
        f"No checkpoint at {CKPT_PATH}. Run train.py first."
    )

model = GMAI(max_seq=SEQ_LEN)
model.load_state_dict(torch.load(CKPT_PATH, map_location="cpu"))
model.eval()

norm = NormStats.load(NORM_PATH)

print(f"GM-AI model loaded ({sum(p.numel() for p in model.parameters()):,} params)")
print(f"Listening on http://localhost:{PORT}/predict")

# ── Server ────────────────────────────────────────────────────────────────────

app = Flask(__name__)


@app.route("/predict", methods=["POST"])
def predict():
    data = request.get_json(force=True)
    snapshots = data.get("snapshots", [])

    if not snapshots:
        return jsonify({"error": "no snapshots provided"}), 400

    # Build (SEQ_LEN, N_FEATURES) array, zero-padding if needed
    arr = np.array(snapshots, dtype=np.float32)
    if arr.shape[1] != N_FEATURES:
        return jsonify({"error": f"expected {N_FEATURES} features, got {arr.shape[1]}"}), 400

    T = arr.shape[0]
    if T < SEQ_LEN:
        pad = np.zeros((SEQ_LEN - T, N_FEATURES), dtype=np.float32)
        arr = np.concatenate([pad, arr], axis=0)
    else:
        arr = arr[-SEQ_LEN:]  # keep most recent

    arr = norm.apply(arr)
    x   = torch.tensor(arr, dtype=torch.float32).unsqueeze(0)  # (1, T, F)

    with torch.no_grad():
        weights = model(x).squeeze(0).tolist()  # (A,)

    result = {action: round(w, 4) for action, w in zip(ACTIONS, weights)}
    return jsonify({"actions": result})


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=PORT, debug=False)
