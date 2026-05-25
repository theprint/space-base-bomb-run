"""
Export the trained GM-AI model to ONNX format.

Usage:
    python gm_ai/export_onnx.py

Output: gm_ai/checkpoints/gmai.onnx

Note on Godot integration:
    Godot 4 has no built-in ONNX runtime. Options for deployment:
      1. Run serve.py alongside the game (recommended, no extra setup).
      2. A GDExtension wrapping onnxruntime (experimental community plugins exist).
      3. Export weights to JSON and implement the forward pass in GDScript
         (feasible for this model size ~55K params).
"""

import os
import torch
from model   import GMAI
from dataset import SEQ_LEN, N_FEATURES

CKPT_DIR  = os.path.join(os.path.dirname(__file__), "checkpoints")
CKPT_PATH = os.path.join(CKPT_DIR, "best.pt")
ONNX_PATH = os.path.join(CKPT_DIR, "gmai.onnx")

if not os.path.exists(CKPT_PATH):
    raise FileNotFoundError(f"No checkpoint found at {CKPT_PATH}. Run train.py first.")

model = GMAI(max_seq=SEQ_LEN)
model.load_state_dict(torch.load(CKPT_PATH, map_location="cpu"))
model.eval()

dummy = torch.zeros(1, SEQ_LEN, N_FEATURES)

torch.onnx.export(
    model,
    dummy,
    ONNX_PATH,
    input_names=["snapshots"],
    output_names=["action_weights"],
    dynamic_axes={
        "snapshots":      {0: "batch"},
        "action_weights": {0: "batch"},
    },
    opset_version=17,
)

print(f"Exported to {ONNX_PATH}")
print("Verify with: python -c \"import onnx; onnx.checker.check_model(onnx.load('" + ONNX_PATH + "'))\"")
