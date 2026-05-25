"""
GM-AI training script.

Usage:
    cd Space-Base-Bomb-Run
    pip install -r gm_ai/requirements.txt
    python gm_ai/train.py

Outputs (all in gm_ai/checkpoints/):
    best.pt          — best model weights
    norm_stats.json  — feature normalisation (mean/std)
    loss_log.csv     — epoch-level train/val loss
"""

import os
import csv
import random
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, random_split

from model   import GMAI, N_FEATURES, N_ACTIONS
from dataset import load_dataset, SEQ_LEN

# ── Config ───────────────────────────────────────────────────────────────────

DATA_CSV   = os.path.join(os.path.dirname(__file__), "..", "data", "master_data.csv")
CKPT_DIR   = os.path.join(os.path.dirname(__file__), "checkpoints")
NORM_PATH  = os.path.join(CKPT_DIR, "norm_stats.json")
CKPT_PATH  = os.path.join(CKPT_DIR, "best.pt")
LOG_PATH   = os.path.join(CKPT_DIR, "loss_log.csv")

EPOCHS       = 300
BATCH_SIZE   = 32
LR           = 1e-3
VAL_SPLIT    = 0.2
SEED         = 42
PATIENCE     = 25   # early stopping — epochs without val improvement
MIN_SAMPLES  = 20   # warn if fewer labeled rows than this

# ── Setup ─────────────────────────────────────────────────────────────────────

random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

os.makedirs(CKPT_DIR, exist_ok=True)
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

# ── Data ──────────────────────────────────────────────────────────────────────

print(f"Loading data from {DATA_CSV} ...")
dataset, norm = load_dataset(DATA_CSV, norm_path=NORM_PATH, seq_len=SEQ_LEN)

n_total = len(dataset)
print(f"  Windows: {n_total}  (seq_len={SEQ_LEN})")

if n_total < MIN_SAMPLES:
    print(f"\n  WARNING: Only {n_total} training windows available.")
    print(f"  Label at least {MIN_SAMPLES} rows for meaningful training.\n")

n_val   = max(1, int(n_total * VAL_SPLIT))
n_train = n_total - n_val
train_ds, val_ds = random_split(dataset, [n_train, n_val],
                                generator=torch.Generator().manual_seed(SEED))

train_dl = DataLoader(train_ds, batch_size=BATCH_SIZE, shuffle=True,  drop_last=False)
val_dl   = DataLoader(val_ds,   batch_size=BATCH_SIZE, shuffle=False, drop_last=False)

# ── Model ─────────────────────────────────────────────────────────────────────

model = GMAI(max_seq=SEQ_LEN).to(device)
n_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
print(f"Model: {n_params:,} trainable parameters  (device={device})")

optimizer = torch.optim.Adam(model.parameters(), lr=LR, weight_decay=1e-4)
scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=EPOCHS)

# ── Loss ──────────────────────────────────────────────────────────────────────

def loss_fn(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """
    KL divergence between predicted distribution and soft target labels.
    pred:   (B, A) — already softmax'd
    target: (B, A) — normalised weights summing to 1
    """
    # Clamp to avoid log(0)
    log_pred = torch.log(pred.clamp(min=1e-9))
    return F.kl_div(log_pred, target, reduction="batchmean")

# ── Train loop ────────────────────────────────────────────────────────────────

best_val      = float("inf")
patience_left = PATIENCE

with open(LOG_PATH, "w", newline="") as f:
    csv.writer(f).writerow(["epoch", "train_loss", "val_loss", "lr"])

print(f"\n{'Epoch':>6}  {'Train':>9}  {'Val':>9}  {'LR':>9}")
print("─" * 44)

for epoch in range(1, EPOCHS + 1):
    # Train
    model.train()
    train_loss = 0.0
    for X, y in train_dl:
        X, y = X.to(device), y.to(device)
        optimizer.zero_grad()
        pred = model(X)
        loss = loss_fn(pred, y)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()
        train_loss += loss.item() * len(X)
    train_loss /= n_train

    # Validate
    model.eval()
    val_loss = 0.0
    with torch.no_grad():
        for X, y in val_dl:
            X, y = X.to(device), y.to(device)
            val_loss += loss_fn(model(X), y).item() * len(X)
    val_loss /= n_val

    scheduler.step()
    current_lr = scheduler.get_last_lr()[0]

    # Checkpoint + early stopping
    if val_loss < best_val:
        best_val = val_loss
        patience_left = PATIENCE
        torch.save(model.state_dict(), CKPT_PATH)
        marker = " *"
    else:
        patience_left -= 1
        marker = ""

    if epoch % 10 == 0 or epoch == 1:
        print(f"{epoch:>6}  {train_loss:>9.4f}  {val_loss:>9.4f}  {current_lr:>9.2e}{marker}")

    with open(LOG_PATH, "a", newline="") as f:
        csv.writer(f).writerow([epoch, f"{train_loss:.6f}", f"{val_loss:.6f}", f"{current_lr:.2e}"])

    if patience_left == 0:
        print(f"\nEarly stop at epoch {epoch} — no val improvement for {PATIENCE} epochs.")
        break

print("─" * 44)
print(f"Done. Best val loss: {best_val:.4f}")
print(f"Checkpoint: {CKPT_PATH}")
print(f"Norm stats: {NORM_PATH}")
