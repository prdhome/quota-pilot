#!/usr/bin/env bash
# quota-reserve.sh — 額度重置卷／點數清單（~/.claude/state/quota-reserves.json），供 quota-mode.sh 判斷「有卷可用」與提示用卷。
#   list                         列出未用、未過期的卷與點數
#   use <claude|codex>           標記最早到期的可用卷為已用（記 used_at 與當下週 reset，日後比對「用卷是否重開 7 天週期」）
#   add <claude|codex> <ISO8601> 新增一張卷（例 2026-11-14T02:00:00+08:00）
#   check                        比對已用卷的 reset 前後：週 reset 時間有變 → 用卷會重開週期
# 重置卷沒有 API，用卷後要手動 `use`；`QUOTA_RESERVES` 可改檔案路徑（測試用）。
F="${QUOTA_RESERVES:-$HOME/.claude/state/quota-reserves.json}"
cmd="${1:-list}"; shift || true
python3 -I - "$F" "$cmd" "$@" <<'PY'
import json, os, sys, time
from datetime import datetime
f, cmd, *a = sys.argv[1:]
d = json.load(open(f)) if os.path.exists(f) else {"cards": [], "credits": []}
now = time.time()
ts = lambda s: datetime.fromisoformat(s).timestamp()
def week_reset(p):
    try:
        if p == "claude": return float(json.load(open(os.path.expanduser("~/.claude/state/rate_limits.json")))["seven_day_resets_at"])
        return float(json.load(open(os.path.expanduser("~/.claude/state/codex_limits.json")))["row"][3])
    except Exception: return None
def save(): json.dump(d, open(f, "w"), ensure_ascii=False, indent=2)
live = lambda c: not c.get("used_at") and ts(c["expires"]) > now
if cmd == "list":
    for c in sorted(d["cards"], key=lambda c: c["expires"]):
        st = "已用 " + c["used_at"] if c.get("used_at") else ("過期" if ts(c["expires"]) <= now else f"可用，剩 {(ts(c['expires']) - now) / 86400:.1f} 天")
        print(f"{c['provider']:6} 卷  到期 {c['expires']}  {st}")
    for c in d.get("credits", []):
        print(f"{c['provider']} 點數 US${c['usd_left']}/{c['usd_total']}  到期 {c['expires']}  {c.get('note', '')}")
elif cmd == "use":
    p = a[0] if a else sys.exit("usage: use <claude|codex>")
    cs = sorted((c for c in d["cards"] if c["provider"] == p and live(c)), key=lambda c: c["expires"])
    if not cs: sys.exit(f"沒有可用的 {p} 卷")
    cs[0]["used_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
    cs[0]["reset7_before"] = week_reset(p)
    save(); print(f"已標記 {p} 卷（到期 {cs[0]['expires']}）為已用；幾分鐘後跑 `quota-reserve.sh check` 看週期是否重開")
elif cmd == "add":
    if len(a) < 2: sys.exit("usage: add <claude|codex> <ISO8601>")
    ts(a[1]); d["cards"].append({"provider": a[0], "expires": a[1], "used_at": None}); save(); print("已新增")
elif cmd == "check":
    for c in d["cards"]:
        if c.get("used_at") and c.get("reset7_before"):
            r = week_reset(c["provider"])
            if r is None: print(f"{c['provider']}：讀不到目前週 reset"); continue
            same = abs(r - c["reset7_before"]) < 600
            print(f"{c['provider']} 卷（用於 {c['used_at']}）：週 reset {'未變 → 只歸零用量、不重開週期' if same else '已改變 → 用卷會重開 7 天週期'}")
else: sys.exit(f"未知指令 {cmd}")
PY
