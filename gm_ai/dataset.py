"""
Dataset utilities for GM-AI training.

Loads master_data.csv, splits rows into per-session sequences (detected by
play_time resets), builds sliding windows of length SEQ_LEN, and normalises
features using z-score statistics saved alongside the checkpoint so inference
can apply the same transform.
"""

import json
import os
import numpy as np
import pandas as pd
import torch
from torch.utils.data import Dataset

SEQ_LEN = 8   # number of snapshots per training window

FEATURES = [
    "play_time", "score", "score_gained_10s", "lives",
    "player_x_norm", "player_y_norm", "is_invincible", "time_since_last_hit",
    "enemy_count", "scout_count", "hunter_count", "bruiser_count",
    "total_threat_on_screen", "avg_enemy_y_norm", "nearest_enemy_dist_norm",
    "player_bullets", "enemy_bullets", "spawn_budget",
    "kills_10s", "hits_10s",
]

ACTIONS = [
    "hold",
    "budget_increase", "budget_decrease",
    "rate_increase",   "rate_decrease",
    "force_swarm",     "force_elite",
    "force_chase",     "force_diagonal",
    "force_rest",      "clear_screen",
    "surge",           "ease",
]


def _split_sessions(df: pd.DataFrame, reset_threshold: float = 10.0) -> list[pd.DataFrame]:
    """
    Split a dataframe into per-session chunks.
    A new session is detected whenever play_time drops by more than
    reset_threshold seconds compared to the previous row.
    """
    sessions = []
    start = 0
    for i in range(1, len(df)):
        if df["play_time"].iloc[i] < df["play_time"].iloc[i - 1] - reset_threshold:
            sessions.append(df.iloc[start:i].reset_index(drop=True))
            start = i
    sessions.append(df.iloc[start:].reset_index(drop=True))
    return [s for s in sessions if len(s) > 0]


def _make_windows(session: pd.DataFrame, seq_len: int) -> list[tuple[np.ndarray, np.ndarray]]:
    """
    Create (X_window, y_last) pairs from a single session.
    X_window: (seq_len, n_features) — zero-padded at the start if needed.
    y_last:   (n_actions,)          — label for the final snapshot in window.
    """
    X = session[FEATURES].to_numpy(dtype=np.float32)
    y = session[ACTIONS].to_numpy(dtype=np.float32)

    windows = []
    for end in range(len(session)):
        start = end - seq_len + 1
        if start < 0:
            pad_rows = -start
            window = np.concatenate([
                np.zeros((pad_rows, X.shape[1]), dtype=np.float32),
                X[0:end + 1],
            ], axis=0)
        else:
            window = X[start:end + 1]
        windows.append((window, y[end]))
    return windows


class NormStats:
    """Per-feature mean/std used for z-score normalisation."""

    def __init__(self, mean: np.ndarray, std: np.ndarray):
        self.mean = mean
        self.std  = std

    def apply(self, x: np.ndarray) -> np.ndarray:
        return (x - self.mean) / (self.std + 1e-8)

    def save(self, path: str):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"mean": self.mean.tolist(), "std": self.std.tolist()}, f)

    @classmethod
    def load(cls, path: str) -> "NormStats":
        with open(path) as f:
            d = json.load(f)
        return cls(np.array(d["mean"], dtype=np.float32),
                   np.array(d["std"],  dtype=np.float32))

    @classmethod
    def fit(cls, df: pd.DataFrame) -> "NormStats":
        vals = df[FEATURES].to_numpy(dtype=np.float32)
        return cls(vals.mean(axis=0), vals.std(axis=0))


class GMDataset(Dataset):
    def __init__(self, csv_path: str, norm: NormStats, seq_len: int = SEQ_LEN):
        df = pd.read_csv(csv_path)

        # Drop rows where ALL action weights are 0 (skipped rows)
        action_sum = df[ACTIONS].sum(axis=1)
        df = df[action_sum > 0].reset_index(drop=True)

        sessions = _split_sessions(df)
        all_windows = []
        for s in sessions:
            all_windows.extend(_make_windows(s, seq_len))

        # Normalise X; leave y as-is (already sums to 1)
        self._X = []
        self._y = []
        for window, label in all_windows:
            normed = norm.apply(window)
            self._X.append(torch.tensor(normed, dtype=torch.float32))
            self._y.append(torch.tensor(label,  dtype=torch.float32))

    def __len__(self):
        return len(self._X)

    def __getitem__(self, idx):
        return self._X[idx], self._y[idx]


def load_dataset(csv_path: str, norm_path: str | None = None, seq_len: int = SEQ_LEN):
    """
    Load dataset and fit (or load) normalisation stats.
    Returns (dataset, norm_stats).
    If norm_path is given and exists, load stats from there;
    otherwise fit from data and save to norm_path.
    """
    df = pd.read_csv(csv_path)
    action_sum = df[ACTIONS].sum(axis=1)
    df = df[action_sum > 0].reset_index(drop=True)

    if len(df) == 0:
        raise ValueError("master_data.csv has no labeled rows yet.")

    if norm_path and os.path.exists(norm_path):
        norm = NormStats.load(norm_path)
    else:
        norm = NormStats.fit(df)
        if norm_path:
            norm.save(norm_path)

    dataset = GMDataset(csv_path, norm, seq_len)
    return dataset, norm
