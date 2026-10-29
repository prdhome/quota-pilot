#!/usr/bin/env python3
"""檢查 bin/snapshot.sh 輸出的 JSON 結構；給情境檔時再比對 expect。失敗印原因並 exit 1。
用法：check_snapshot.py <snapshot.json> [tests/fixtures/<情境>.json]
"""
import json, sys, time

errs = []
def need(cond, msg):
    if not cond: errs.append(msg)
num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)

snap = json.load(open(sys.argv[1]))
sc = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None

need(set(snap) == {"generated_at", "mode", "explain", "claude", "codex", "cards", "credits", "detail"}, f"top-level keys {sorted(snap)}")
need(isinstance(snap.get("generated_at"), int) and abs(snap["generated_at"] - time.time()) < 300, f"generated_at {snap.get('generated_at')!r} 不是現在的整數 epoch")
m = snap.get("mode")
need(isinstance(m, dict) and list(m) == ["mode", "hub", "route", "subagent", "claude", "codex", "override", "card"], f"mode keys {m!r}")
if isinstance(m, dict):
    need(m.get("mode", "").isdigit() and 1 <= int(m["mode"]) <= 12, f"mode.mode {m.get('mode')!r}")
    need(m.get("hub") in ("opus", "sonnet") and m.get("subagent") in ("opus", "sonnet"), f"hub/subagent {m.get('hub')}/{m.get('subagent')}")
    need(m.get("route") in ("delegate", "cost", "direct", "no-codex", "small-only", "hold"), f"route {m.get('route')!r}")
    need(m.get("claude") in ("rich", "ok", "tight", "unknown") and m.get("codex") in ("rich", "ok", "lean", "tight", "unknown"), f"tiers {m.get('claude')}/{m.get('codex')}")
need(isinstance(snap.get("explain"), list) and snap["explain"] and all(isinstance(s, str) for s in snap["explain"]), "explain 應為非空字串陣列")

def window(w, where):
    need(isinstance(w, dict) and set(w) == {"used", "resets_at"}, f"{where} keys {w!r}")
    if isinstance(w, dict):
        need(num(w.get("used")) and 0 <= w["used"] <= 100, f"{where}.used {w.get('used')!r}")
        need(w.get("resets_at") is None or num(w["resets_at"]), f"{where}.resets_at {w.get('resets_at')!r}")

for p, keys in (("claude", {"five", "week", "surplus", "updated_at"}), ("codex", {"five", "week", "surplus"})):
    v = snap.get(p)
    if v is None: continue
    need(isinstance(v, dict) and set(v) == keys, f"{p} keys {sorted(v) if isinstance(v, dict) else v!r}")
    if isinstance(v, dict):
        window(v.get("five"), p + ".five"); window(v.get("week"), p + ".week")
        need(v.get("surplus") is None or (num(v["surplus"]) and -100 <= v["surplus"] <= 100), f"{p}.surplus {v.get('surplus')!r}")

need(isinstance(snap.get("cards"), list) and all(isinstance(c, dict) and list(c) == ["provider", "expires", "used_at"] for c in snap.get("cards") or []), f"cards {snap.get('cards')!r}")
need(isinstance(snap.get("credits"), list) and all(isinstance(c, dict) and list(c) == ["provider", "usd_left", "usd_total", "expires"] for c in snap.get("credits") or []), f"credits {snap.get('credits')!r}")

if sc:
    want = sc.get("expect", {})
    if "mode" in want: need(m == want["mode"], f"mode\n  want {want['mode']}\n  got  {m}")
    if "explain_contains" in want: need(any(want["explain_contains"] in s for s in snap.get("explain") or []), f"explain 沒有 {want['explain_contains']!r}")
    need((snap.get("claude") is None) == (sc.get("claude") is None), "claude 有無與情境不符")
    need((snap.get("codex") is None) == (sc.get("codex") is None), "codex 有無與情境不符")
    for p in ("claude", "codex"):
        if sc.get(p) and snap.get(p):
            need(snap[p]["week"]["used"] == sc[p]["week_used"] and snap[p]["five"]["used"] == sc[p]["five_used"], f"{p} 用量與情境不符")
    r = sc.get("reserves") or {}
    need(len(snap.get("cards") or []) == len(r.get("cards", [])) and len(snap.get("credits") or []) == len(r.get("credits", [])), "卷／點數數量與情境不符")

if errs:
    print("\n".join(errs)); sys.exit(1)
