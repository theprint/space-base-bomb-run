#!/usr/bin/env python3
"""
Space Base Bomb Run — GM-AI Telemetry Labeler
=============================================
Usage:
    pip install flask
    python tools/labeler.py
Then open http://localhost:5000 in your browser.

Workflow:
    1. Pick a session CSV from the list.
    2. For each snapshot you see the screenshot + key stats.
    3. Click 1–3 actions (ranked by order of click), adjust weights if needed.
    4. "Label & Next" appends the row to data/master_data.csv and advances.
    5. "Skip" moves forward without writing anything.
"""

import csv
import json
import os
import glob
from flask import Flask, request, redirect, url_for, send_file, render_template_string, abort

app = Flask(__name__)

DATA   = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data"))
MASTER = os.path.join(DATA, "master_data.csv")

ACTIONS = [
    "hold",
    "budget_increase", "budget_decrease",
    "rate_increase",   "rate_decrease",
    "force_swarm",     "force_elite",
    "force_chase",     "force_diagonal",
    "force_rest",      "clear_screen",
    "surge",           "ease",
]

# Displayed stats (subset of CSV columns — excludes raw positions and timestamps)
TEL_COLS = [
    "play_time", "score", "score_gained_10s", "lives",
    "player_x_norm", "player_y_norm", "is_invincible", "time_since_last_hit",
    "enemy_count", "scout_count", "hunter_count", "bruiser_count",
    "total_threat_on_screen", "avg_enemy_y_norm", "nearest_enemy_dist_norm",
    "player_bullets", "enemy_bullets", "spawn_budget",
    "kills_10s", "hits_10s",
]

MASTER_COLS = TEL_COLS + ACTIONS

ACTION_CATS = {
    "hold":            "cat-neutral",
    "budget_increase": "cat-budget",   "budget_decrease": "cat-budget",
    "rate_increase":   "cat-rate",     "rate_decrease":   "cat-rate",
    "force_swarm":     "cat-force",    "force_elite":     "cat-force",
    "force_chase":     "cat-force",    "force_diagonal":  "cat-force",
    "force_rest":      "cat-emergency","clear_screen":    "cat-emergency",
    "surge":           "cat-compound", "ease":            "cat-compound",
}

ACTION_DESC = {
    "hold":            "Skip this tick only. No spawn, no changes.",
    "budget_increase": "Grow next wave slightly (more/stronger enemies).",
    "budget_decrease": "Shrink next wave slightly (fewer/weaker enemies).",
    "rate_increase":   "Spawn more often — shorter gap between waves.",
    "rate_decrease":   "Spawn less often — longer gap between waves.",
    "force_swarm":     "Spawn 4 enemies at once. Screen too empty.",
    "force_elite":     "Force a bruiser (elite, red) to spawn next.",
    "force_chase":     "Force hunters that track the player's position.",
    "force_diagonal":  "Force a diagonal wave (random left or right).",
    "force_rest":      "Skip next 3 ticks — deliberate breather, not just one tick.",
    "clear_screen":    "Instantly remove ALL enemies. Emergency only.",
    "surge":           "Raise budget + speed up spawns. Max pressure.",
    "ease":            "Lower budget + slow spawns + skip next spawn. Max relief.",
}

# ── helpers ──────────────────────────────────────────────────────────────────

PROGRESS_FILE = os.path.join(DATA, "progress.json")

def _load_progress() -> dict:
    if os.path.exists(PROGRESS_FILE):
        with open(PROGRESS_FILE, encoding="utf-8") as f:
            return json.load(f)
    return {}

def _save_progress(prog: dict):
    os.makedirs(DATA, exist_ok=True)
    with open(PROGRESS_FILE, "w", encoding="utf-8") as f:
        json.dump(prog, f)

def _mark_labeled(session_id: str, row: int):
    prog = _load_progress()
    labeled = set(prog.get(session_id, []))
    labeled.add(row)
    prog[session_id] = sorted(labeled)
    _save_progress(prog)

def _first_unlabeled(session_id: str, total: int) -> int:
    prog = _load_progress()
    labeled = set(prog.get(session_id, []))
    for i in range(total):
        if i not in labeled:
            return i
    return total  # all done

def _sessions():
    files = glob.glob(os.path.join(DATA, "*.csv"))
    return sorted(f for f in files if "master_data" not in os.path.basename(f))

def _read(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def _shot(session_id, idx):
    return os.path.join(DATA, "screenshots", session_id, f"snap_{int(idx):05d}.png")

def _ensure_master():
    os.makedirs(DATA, exist_ok=True)
    if not os.path.exists(MASTER):
        with open(MASTER, "w", newline="", encoding="utf-8") as f:
            csv.DictWriter(f, fieldnames=MASTER_COLS).writeheader()

def _append(row: dict):
    _ensure_master()
    with open(MASTER, "a", newline="", encoding="utf-8") as f:
        csv.DictWriter(f, fieldnames=MASTER_COLS).writerow(row)

def _master_count():
    if not os.path.exists(MASTER):
        return 0
    return max(0, len(_read(MASTER)))

# ── routes ───────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    prog = _load_progress()
    sessions = []
    for path in _sessions():
        name = os.path.splitext(os.path.basename(path))[0]
        total = len(_read(path))
        labeled_count = len(prog.get(name, []))
        first_unlabeled = _first_unlabeled(name, total)
        sessions.append({
            "name": name,
            "rows": total,
            "labeled": labeled_count,
            "pct": int(labeled_count / total * 100) if total else 0,
            "done": labeled_count >= total,
            "resume": first_unlabeled,
        })
    return render_template_string(INDEX_HTML, sessions=sessions,
                                  master_rows=_master_count(), data_dir=DATA)

@app.route("/label/<session_id>/<int:row>")
def label(session_id, row):
    csv_path = os.path.join(DATA, session_id + ".csv")
    if not os.path.exists(csv_path):
        abort(404)
    rows = _read(csv_path)
    if row >= len(rows):
        return render_template_string(DONE_HTML, session_id=session_id, total=len(rows))
    r = rows[row]
    snap_idx = r.get("snapshot_index", "0")
    return render_template_string(LABEL_HTML,
        session_id=session_id, row=row, total=len(rows),
        has_shot=os.path.exists(_shot(session_id, snap_idx)),
        snap_index=snap_idx,
        raw={k: r.get(k, "") for k in TEL_COLS},
        lives=r.get("lives", "?"),
        score=r.get("score", "?"),
        score_gained=r.get("score_gained_10s", "0"),
        play_time=float(r.get("play_time", 0)),
        enemy_count=r.get("enemy_count", "0"),
        scout_count=r.get("scout_count", "0"),
        hunter_count=r.get("hunter_count", "0"),
        bruiser_count=r.get("bruiser_count", "0"),
        threat=r.get("total_threat_on_screen", "0"),
        budget=r.get("spawn_budget", "?"),
        last_hit=r.get("time_since_last_hit", "?"),
        is_invinc=r.get("is_invincible", "0") == "1",
        kills=r.get("kills_10s", "0"),
        hits=r.get("hits_10s", "0"),
        pbullets=r.get("player_bullets", "0"),
        ebullets=r.get("enemy_bullets", "0"),
        actions=ACTIONS,
        cat=ACTION_CATS,
        desc=ACTION_DESC,
    )

@app.route("/label/<session_id>/<int:row>", methods=["POST"])
def submit(session_id, row):
    csv_path = os.path.join(DATA, session_id + ".csv")
    rows = _read(csv_path)
    if row >= len(rows):
        return redirect(url_for("index"))
    r = rows[row]
    actions_data = json.loads(request.form.get("actions_json", "[]"))

    # Normalise weights to sum to 1.0
    total = sum(a["weight"] for a in actions_data)
    if total > 0:
        for a in actions_data:
            a["weight"] /= total

    out = {col: r.get(col, "") for col in TEL_COLS}
    for action in ACTIONS:
        match = next((a for a in actions_data if a["action"] == action), None)
        out[action] = f"{match['weight']:.4f}" if match else "0.0000"

    _append(out)
    _mark_labeled(session_id, row)
    return redirect(url_for("label", session_id=session_id, row=row + 1))

@app.route("/screenshot/<session_id>/<int:index>")
def screenshot(session_id, index):
    path = os.path.abspath(_shot(session_id, index))
    if not os.path.exists(path):
        abort(404)
    return send_file(path, mimetype="image/png")

# ── templates ─────────────────────────────────────────────────────────────────

INDEX_HTML = """<!DOCTYPE html>
<html><head><title>GM-AI Labeler</title><meta charset="utf-8">
<style>
  body{background:#0f0f1a;color:#e0e0e0;font-family:'Courier New',monospace;padding:32px;max-width:700px;margin:0 auto}
  h1{color:#60a5fa;letter-spacing:3px;margin-bottom:6px;font-size:20px}
  .sub{color:#555;font-size:11px;margin-bottom:28px}
  .session{background:#1a1a2e;border:1px solid #2a2a4a;border-radius:6px;padding:14px 18px;
           margin-bottom:10px;display:flex;flex-direction:column;gap:8px}
  .session-row{display:flex;align-items:center;gap:16px}
  .name{flex:1;font-size:14px}
  .rows{color:#555;font-size:12px;white-space:nowrap}
  .prog-wrap{height:4px;background:#222;border-radius:2px;width:100%}
  .prog-fill{height:4px;border-radius:2px;transition:width .3s}
  .fill-done{background:#4ade80}
  .fill-partial{background:#60a5fa}
  .prog-label{font-size:10px;color:#555;display:flex;justify-content:space-between}
  .prog-label .pct-done{color:#4ade80}
  .prog-label .pct-partial{color:#60a5fa}
  .btn{color:#000;border:none;padding:8px 18px;border-radius:4px;
       cursor:pointer;font-family:monospace;font-weight:bold;text-decoration:none;font-size:13px;white-space:nowrap}
  .btn-go{background:#4ade80}.btn-go:hover{background:#6ee7a0}
  .btn-cont{background:#60a5fa}.btn-cont:hover{background:#93c5fd}
  .btn-done{background:#333;color:#666;pointer-events:none}
  .empty{color:#333;font-size:13px;padding:20px 0}
  .footer{margin-top:24px;padding:12px 16px;background:#111;border-radius:4px;
          color:#444;font-size:12px;border-left:3px solid #222}
  .footer span{color:#60a5fa}
</style></head>
<body>
<h1>&#9670; GM-AI LABELER</h1>
<div class="sub">{{ data_dir }}</div>
{% for s in sessions %}
<div class="session">
  <div class="session-row">
    <div class="name">{{ s.name }}</div>
    <div class="rows">{{ s.rows }} rows</div>
    {% if s.done %}
    <a class="btn btn-done">DONE &#10003;</a>
    {% elif s.labeled > 0 %}
    <a href="/label/{{ s.name }}/{{ s.resume }}" class="btn btn-cont">CONTINUE &rarr;</a>
    {% else %}
    <a href="/label/{{ s.name }}/0" class="btn btn-go">LABEL &rarr;</a>
    {% endif %}
  </div>
  <div class="prog-wrap">
    <div class="prog-fill {{ 'fill-done' if s.done else 'fill-partial' }}" style="width:{{ s.pct }}%"></div>
  </div>
  <div class="prog-label">
    <span>{{ s.labeled }} / {{ s.rows }} labeled</span>
    <span class="{{ 'pct-done' if s.done else 'pct-partial' }}">{{ s.pct }}%</span>
  </div>
</div>
{% else %}
<div class="empty">No session CSV files found. Run the game first.</div>
{% endfor %}
<div class="footer">master_data.csv &mdash; <span>{{ master_rows }}</span> rows labeled</div>
</body></html>"""

DONE_HTML = """<!DOCTYPE html>
<html><head><title>Done</title><meta charset="utf-8">
<style>body{background:#0f0f1a;color:#e0e0e0;font-family:monospace;
      padding:60px;text-align:center}h2{color:#4ade80;letter-spacing:2px;margin-bottom:12px}
      a{color:#60a5fa}p{color:#888;margin-bottom:20px}</style></head>
<body>
<h2>&#10003; SESSION COMPLETE</h2>
<p>All {{ total }} rows from <b>{{ session_id }}</b> have been reviewed.</p>
<a href="/">&larr; Back to sessions</a>
</body></html>"""

LABEL_HTML = """<!DOCTYPE html>
<html><head><title>GM-AI Labeler</title><meta charset="utf-8">
<style>
:root{--bg:#0f0f1a;--s1:#1a1a2e;--s2:#16213e;--text:#e0e0e0;--dim:#666;
      --green:#4ade80;--red:#f87171;--orange:#fb923c;--blue:#60a5fa;--purple:#c084fc;--yellow:#facc15}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Courier New',monospace;font-size:13px;height:100vh;display:flex;flex-direction:column}

header{background:var(--s2);padding:10px 20px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #2a2a4a;flex-shrink:0}
header h1{font-size:15px;color:var(--blue);letter-spacing:2px}
.prog{color:var(--dim);font-size:12px}
.prog-bar-wrap{width:180px;height:4px;background:#333;border-radius:2px}
.prog-bar{height:4px;background:var(--blue);border-radius:2px}

.layout{display:grid;grid-template-columns:1fr 1fr;gap:16px;padding:14px;flex:1;min-height:0}

.left{display:flex;flex-direction:column;gap:8px;min-height:0}
.shot{width:100%;border:1px solid #2a2a4a;background:#000;display:block}
.no-shot{width:100%;aspect-ratio:16/9;background:#0a0a14;border:1px dashed #2a2a4a;
         display:flex;align-items:center;justify-content:center;color:#333;font-size:12px}
details summary{color:#333;cursor:pointer;font-size:10px;user-select:none}
.raw-vals{color:#444;font-size:10px;line-height:1.9;padding-top:6px;columns:2;column-gap:16px}

.right{display:flex;flex-direction:column;gap:10px;overflow-y:auto;padding-right:4px}

.stats-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;flex-shrink:0}
.card{background:var(--s1);border:1px solid #2a2a4a;border-radius:5px;padding:8px 10px}
.card .lbl{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:1px}
.card .val{font-size:19px;font-weight:bold;margin-top:1px}
.card .sub{color:var(--dim);font-size:10px;margin-top:1px}
.g{color:var(--green)}.r{color:var(--red)}.o{color:var(--orange)}.b{color:var(--blue)}

.sec{color:var(--dim);font-size:10px;text-transform:uppercase;letter-spacing:1px;
     border-bottom:1px solid #2a2a4a;padding-bottom:4px;flex-shrink:0}

.action-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:5px;flex-shrink:0}
.abtn{padding:7px 6px;border:1px solid #2a2a4a;border-radius:4px;background:var(--s1);
      color:inherit;cursor:pointer;font-family:monospace;font-size:11px;text-align:center;
      transition:background 0.1s,border-color 0.1s;user-select:none;line-height:1.3;display:flex;flex-direction:column;gap:3px}
.abtn .aname{font-weight:bold}
.abtn .adesc{font-size:9px;color:#666;font-weight:normal;line-height:1.3;text-align:left}
.abtn:hover{background:var(--s2);border-color:#444}
.abtn.r1{border:2px solid var(--green)!important;background:rgba(74,222,128,.12)}
.abtn.r2{border:2px solid var(--blue)!important;background:rgba(96,165,250,.12)}
.abtn.r3{border:2px solid var(--purple)!important;background:rgba(192,132,252,.12)}
.cat-neutral{color:var(--dim)}
.cat-budget{color:var(--blue)}.cat-rate{color:var(--yellow)}
.cat-force{color:var(--orange)}.cat-emergency{color:var(--red)}.cat-compound{color:var(--purple)}

#weightEditor{flex-shrink:0}
.wrow{display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:4px;background:var(--s1);margin-bottom:4px}
.badge{width:18px;height:18px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:bold;flex-shrink:0}
.b1{background:rgba(74,222,128,.25);color:var(--green)}.b2{background:rgba(96,165,250,.25);color:var(--blue)}.b3{background:rgba(192,132,252,.25);color:var(--purple)}
.wname{flex:1;font-size:12px}
.wbar{flex:2;height:5px;background:#333;border-radius:3px;overflow:hidden}
.wfill{height:5px;border-radius:3px;transition:width .15s}
.f1{background:var(--green)}.f2{background:var(--blue)}.f3{background:var(--purple)}
.winput{width:58px;background:#0f0f1a;border:1px solid #444;color:var(--text);
        padding:3px 6px;border-radius:3px;font-family:monospace;font-size:12px;text-align:right}
.sum-ok{color:var(--green)}.sum-bad{color:var(--red)}

.btns{display:flex;gap:8px;flex-shrink:0;margin-top:auto;padding-top:6px}
.btn-go{background:var(--green);color:#000;border:none;flex:2;padding:10px;border-radius:4px;
        cursor:pointer;font-family:monospace;font-weight:bold;font-size:13px;letter-spacing:1px}
.btn-go:disabled{background:#333;color:#666;cursor:not-allowed}
.btn-skip{background:var(--s2);color:var(--dim);border:1px solid #2a2a4a;flex:1;padding:10px;
          border-radius:4px;cursor:pointer;font-family:monospace;font-size:13px;text-decoration:none;
          text-align:center;display:block;line-height:1}
.btn-skip:hover{color:var(--text)}
</style>
</head><body>

<header>
  <h1>&#9670; GM-AI LABELER</h1>
  <div style="display:flex;align-items:center;gap:16px">
    <div class="prog-bar-wrap"><div class="prog-bar" style="width:{{ ((row+1)/total*100)|int }}%"></div></div>
    <span class="prog">{{ session_id }} &nbsp;&#124;&nbsp; {{ row+1 }} / {{ total }}</span>
  </div>
</header>

<div class="layout">

  <!-- Left: screenshot + raw dump -->
  <div class="left">
    {% if has_shot %}
    <img class="shot" src="/screenshot/{{ session_id }}/{{ snap_index }}" alt="snapshot">
    {% else %}
    <div class="no-shot">no screenshot for this row</div>
    {% endif %}
    <details>
      <summary>raw values</summary>
      <div class="raw-vals">
        {% for k,v in raw.items() %}<span style="color:#444">{{k}}:</span> {{v}}<br>{% endfor %}
      </div>
    </details>
  </div>

  <!-- Right: stats + action picker -->
  <div class="right">

    <div class="stats-grid">
      <div class="card">
        <div class="lbl">Lives</div>
        <div class="val {{ 'g' if lives|int >= 2 else ('o' if lives|int == 1 else 'r') }}">{{ lives }}</div>
      </div>
      <div class="card">
        <div class="lbl">Score</div>
        <div class="val b">{{ score }}</div>
        <div class="sub">+{{ score_gained }} / 10s</div>
      </div>
      <div class="card">
        <div class="lbl">Play Time</div>
        <div class="val">{{ "%.1f"|format(play_time) }}s</div>
      </div>
      <div class="card">
        <div class="lbl">Enemies</div>
        <div class="val {{ 'o' if enemy_count|int >= 3 else '' }}">{{ enemy_count }}</div>
        <div class="sub">{{ scout_count }}s &middot; {{ hunter_count }}h &middot; {{ bruiser_count }}b</div>
      </div>
      <div class="card">
        <div class="lbl">Threat</div>
        <div class="val {{ 'r' if threat|float >= 12 else ('o' if threat|float >= 6 else 'g') }}">{{ "%.1f"|format(threat|float) }}</div>
        <div class="sub">budget {{ "%.1f"|format(budget|float) }}</div>
      </div>
      <div class="card">
        <div class="lbl">Since Hit</div>
        <div class="val {{ 'g' if last_hit|float >= 10 else ('o' if last_hit|float >= 4 else 'r') }}">{{ "%.1f"|format(last_hit|float) }}s</div>
        <div class="sub">{{ '[shield]' if is_invinc else '' }}</div>
      </div>
      <div class="card">
        <div class="lbl">Kills /10s</div>
        <div class="val g">{{ kills }}</div>
      </div>
      <div class="card">
        <div class="lbl">Hits /10s</div>
        <div class="val {{ 'r' if hits|int >= 2 else ('o' if hits|int == 1 else 'g') }}">{{ hits }}</div>
      </div>
      <div class="card">
        <div class="lbl">Bullets P/E</div>
        <div class="val">{{ pbullets }}<span style="color:#333">/</span>{{ ebullets }}</div>
      </div>
    </div>

    <div class="sec">Select 1&#8211;3 Actions &nbsp;<span id="sumDisplay" style="font-size:11px;letter-spacing:0;text-transform:none"></span></div>

    <div class="action-grid">
      {% for action in actions %}
      <div class="abtn {{ cat[action] }}" data-action="{{ action }}" onclick="toggle(this)">
        <span class="aname">{{ action.replace('_',' ') }}</span>
        <span class="adesc">{{ desc[action] }}</span>
      </div>
      {% endfor %}
    </div>

    <div id="weightEditor" style="display:none"></div>

    <form id="labelForm" method="POST">
      <input type="hidden" name="actions_json" id="actionsJson">
    </form>

    <div class="btns">
      <button class="btn-go" id="submitBtn" disabled onclick="doSubmit()">LABEL &amp; NEXT &rarr;</button>
      <a class="btn-skip" href="/label/{{ session_id }}/{{ row+1 }}">SKIP</a>
    </div>

  </div>
</div>

<script>
const MAX = 3;
let sel = []; // [{action, weight}]

const DEF = [[1.0],[0.6,0.4],[0.5,0.3,0.2]];
const RCLS = ['r1','r2','r3'];
const BCLS = ['b1','b2','b3'];
const FCLS = ['f1','f2','f3'];

function toggle(btn){
  const a = btn.dataset.action;
  const i = sel.findIndex(s=>s.action===a);
  if(i>=0){ sel.splice(i,1); }
  else if(sel.length<MAX){ sel.push({action:a,weight:0}); }
  applyDefaults(); redraw();
}

function applyDefaults(){
  const d = DEF[Math.max(0,sel.length-1)]||[];
  sel.forEach((s,i)=>s.weight=d[i]??0.1);
}

function redraw(){
  document.querySelectorAll('.abtn').forEach(b=>{
    b.classList.remove(...RCLS);
    const i=sel.findIndex(s=>s.action===b.dataset.action);
    if(i>=0) b.classList.add(RCLS[i]);
  });

  const ed=document.getElementById('weightEditor');
  document.getElementById('submitBtn').disabled=sel.length===0;
  if(sel.length===0){ed.style.display='none';updateSum();return;}
  ed.style.display='';

  ed.innerHTML=sel.map((s,i)=>{
    const pct=Math.round(s.weight*100);
    return `<div class="wrow">
      <div class="badge ${BCLS[i]}">${i+1}</div>
      <div class="wname">${s.action.replace(/_/g,' ')}</div>
      <div class="wbar"><div class="wfill ${FCLS[i]}" id="bar${i}" style="width:${pct}%"></div></div>
      <input class="winput" type="number" min="0" max="1" step="0.05" value="${s.weight.toFixed(2)}"
             oninput="upw(${i},parseFloat(this.value)||0)">
    </div>`;
  }).join('');
  updateSum();
}

function upw(i,v){
  sel[i].weight=v;
  const pct=Math.round(v*100);
  document.getElementById('bar'+i).style.width=pct+'%';
  updateSum();
}

function updateSum(){
  const sum=sel.reduce((a,s)=>a+s.weight,0);
  const el=document.getElementById('sumDisplay');
  el.textContent=sel.length?`(sum: ${sum.toFixed(2)})`:'';
  el.className=Math.abs(sum-1)<0.011?'sum-ok':'sum-bad';
}

function doSubmit(){
  document.getElementById('actionsJson').value=JSON.stringify(sel);
  document.getElementById('labelForm').submit();
}
</script>
</body></html>"""

# ── entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"Data directory : {DATA}")
    print(f"Master CSV     : {MASTER}")
    print(f"Open           : http://localhost:5000")
    app.run(debug=False, port=5000)
