# GM-AI Training Guide

## Overview

The GM-AI is a small transformer model that watches rolling snapshots of game state and outputs a weighted distribution over 13 game-master actions (e.g. increase spawn budget, force a rest wave, clear the screen). It is trained on human-labeled telemetry data collected while playing the game.

---

## Step 1 — Collect telemetry

Play the game normally. Every 4 seconds, `telemetry.gd` writes a snapshot row to a CSV file in `data/`. Screenshots are saved alongside each row.

Each session produces one CSV file named after the datetime, e.g. `data/2026-05-04T19-10-19.csv`.

---

## Step 2 — Label sessions

With the game closed (or in a separate terminal), run the labeling tool:

```
cd Space-Base-Bomb-Run
python tools/labeler.py
```

Open `http://localhost:5000` in a browser.

For each snapshot you will see the screenshot and key stats. Click 1–3 actions that a good game master *should* have taken at that moment, adjust the relative weights if needed, then click **LABEL & NEXT**. Use **SKIP** for ambiguous rows.

Progress is saved automatically to `data/progress.json`. The index page shows a progress bar per session and a **CONTINUE →** link that jumps to the first unlabeled row.

All labeled rows are appended to `data/master_data.csv`.

### How much data is enough?

The model has ~55K parameters. As a rough guide:

| Labeled rows | Expected result |
|---|---|
| < 100 | Too little — model will overfit immediately, do not trust it |
| 100–500 | Enough to confirm the pipeline works; expect significant overfitting |
| 500–2,000 | Model learns broad patterns but will still overfit; useful as an early test |
| 2,000–5,000 | Meaningful generalisation starts here; val and train loss track each other |
| 5,000–10,000 | Good generalisation across difficulty levels and play styles |

The gap between train loss and val loss is the key signal. If val loss climbs while train loss falls, the model is memorising rather than learning — more data is the primary fix. The regularisation settings (dropout, weight decay, early stopping) buy some extra mileage from a small dataset but cannot substitute for volume.

Aim for variety: label sessions where you played well *and* sessions where you struggled, at different difficulty stages, so the model sees the full range of situations.

---

## Step 3 — Install Python dependencies

```
pip install -r gm_ai/requirements.txt
```

Requires Python 3.11+. A CUDA-capable GPU is not required — training finishes in under a minute on CPU for typical dataset sizes.

---

## Step 4 — Train

```
cd Space-Base-Bomb-Run
python gm_ai/train.py
```

The script will print a loss table every 10 epochs. A `*` marks epochs where the validation loss improved and a new checkpoint was saved.

```
 Epoch      Train        Val         LR
────────────────────────────────────────────
     1     1.2341     1.1893   1.00e-03 *
    10     0.8712     0.9104   9.51e-04 *
    20     0.6543     0.7231   8.09e-04 *
   ...
```

Outputs written to `gm_ai/checkpoints/`:

| File | Contents |
|---|---|
| `best.pt` | Model weights at the lowest validation loss |
| `norm_stats.json` | Feature mean/std used for z-score normalisation — **must travel with the model** |
| `loss_log.csv` | Epoch-by-epoch train and val loss for plotting |

### Signs the model is learning

- Both train and val loss decrease over the first ~50 epochs.
- Val loss plateaus rather than climbing (climbing = overfitting, collect more data).

### Common issues

**"master_data.csv has no labeled rows yet"** — run the labeler first.

**Val loss rises while train loss falls** — overfitting. Label more sessions, especially ones that are different from what you have already labeled (different difficulty stage, different play style).

**Loss doesn't move at all** — check that `master_data.csv` has varied action labels. If every row is labeled `hold`, the model will just predict `hold` for everything.

---

## Step 5 — Export weights

```
cd Space-Base-Bomb-Run
python gm_ai/export_weights.py
```

This exports the trained weights and normalisation stats to `gm_ai/checkpoints/weights.json`, then copy that file to `ai/weights.json` inside the Godot project:

```
cp gm_ai/checkpoints/weights.json ai/weights.json
```

`scenes/gm_inference.gd` loads this file at startup and runs the full transformer forward pass in pure GDScript — no Python process required at runtime.

Re-run this step and copy the file again whenever you retrain.

---

## Step 6 — Play

Run the game. The GM will print its chosen action to the Godot console every spawn tick:

```
GM-AI → budget_increase (0.41)
```

Press **V** in-game to open the visualizer overlay, which shows the network's action probability distribution in real time.

---

## Re-training after more data

Re-run Steps 4 and 5. `train.py` refits normalisation stats from scratch and overwrites `best.pt`. The export step picks up the new weights automatically.

---

## Development note — inference server

`gm_ai/serve.py` runs a Flask HTTP server that the game can query instead of using the embedded weights. This was the original integration path before `gm_inference.gd` existed. It is no longer needed for normal use, but can be handy during active model development: you can retrain and restart the server without the export + copy step each time.

```
python gm_ai/serve.py
```

The game checks for `ai/weights.json` first and only falls back to the server if the file is missing. If neither is available, the GM stands down and the game plays with its default spawner.

---

## File reference

```
Space-Base-Bomb-Run/
  data/
    master_data.csv              ← all labeled rows (training input)
    progress.json                ← labeler progress tracker
    YYYY-MM-DDTHH-MM-SS.csv      ← raw session telemetry
    screenshots/                 ← one folder per session
  gm_ai/
    model.py                     ← GMAI transformer definition
    dataset.py                   ← data loading, windowing, normalisation
    train.py                     ← training loop
    export_weights.py            ← exports weights.json for embedded inference
    serve.py                     ← HTTP inference server (development only)
    checkpoints/
      best.pt                    ← trained weights
      norm_stats.json            ← normalisation stats (required for inference)
      loss_log.csv               ← training history
      weights.json               ← exported weights for Godot (copy to ai/)
  ai/
    weights.json                 ← deployed weights loaded by gm_inference.gd
  scenes/
    gm_inference.gd              ← embedded transformer inference in GDScript
    gm_controller.gd             ← GM action selection and execution
  tools/
    labeler.py                   ← web labeling interface
```
