#!/usr/bin/env bash
# quota-reserve.sh — 額度重置卷／點數清單（~/.claude/state/quota-reserves.json），供 quota-mode.sh 判斷「有卷可用」與提示用卷。
#   list                         列出未用、未過期的卷與點數
#   use <claude|codex>           標記最早到期的可用卷為已用（記 used_at 與當下週 reset，日後比對「用卷是否重開 7 天週期」）
#   add <claude|codex> <ISO8601> 新增一張卷（例 2026-11-14T02:00:00+08:00）
#   check                        比對已用卷的 reset 前後：週 reset 時間有變 → 用卷會重開週期
#   credit <provider> <USD>      更新雲端點數餘額（最早到期、未過期的那筆），並在該筆的 log 追加一筆 {t, usd_left}；
#                                儀表板用 log 算消耗速度與用完日期。餘額變多（加值）時 usd_total 跟著調高。log 只留最近 100 筆。
# 重置卷沒有 API，用卷後要手動 `use`；`QUOTA_RESERVES` 可改檔案路徑（測試用）。
# 測試用：`QP_STATE` 改讀 Claude rate_limits.json 路徑；`QP_CODEX_TSV="<5h> <7d> <5h_reset> <7d_reset>"` 注入 Codex 讀數（`-` = 讀不到）。未設時行為不變。
F="${QUOTA_RESERVES:-$HOME/.claude/state/quota-reserves.json}"
cmd="${1:-list}"; shift || true
python3 -I - "$F" "$cmd" "$@" <<'PY'
import fcntl, json, os, sys, tempfile, time
from datetime import datetime
f, cmd, *a = sys.argv[1:]
# 整個 read-modify-write 持排他鎖；寫入用同目錄唯一暫存檔再 replace（2026-10-29 bin/ 審查）
os.makedirs(os.path.dirname(os.path.abspath(f)), exist_ok=True)
lock = open(f + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
d = json.load(open(f)) if os.path.exists(f) else {"cards": [], "credits": []}
now = time.time()
ts = lambda s: datetime.fromisoformat(s).timestamp()
def week_reset(p):
    try:
        if p == "claude": return float(json.load(open(os.environ.get("QP_STATE") or os.path.expanduser("~/.claude/state/rate_limits.json")))["seven_day_resets_at"])
        if os.environ.get("QP_CODEX_TSV"): return float(os.environ["QP_CODEX_TSV"].split()[3])
        return float(json.load(open(os.path.expanduser("~/.claude/state/codex_limits.json")))["row"][3])
    except Exception: return None
def save():
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(f)), prefix=".quota-reserves.")
    try:
        with os.fdopen(fd, "w") as fh: json.dump(d, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, f)
    except BaseException:
        os.unlink(tmp); raise
live = lambda c: not c.get("used_at") and ts(c["expires"]) > now
if cmd == "list":
    for c in sorted(d["cards"], key=lambda c: ts(c["expires"])):
        st = "已用 " + c["used_at"] if c.get("used_at") else ("過期" if ts(c["expires"]) <= now else f"可用，剩 {(ts(c['expires']) - now) / 86400:.1f} 天")
        print(f"{c['provider']:6} 卷  到期 {c['expires']}  {st}")
    for c in d.get("credits", []):
        last = (c.get("log") or [{}])[-1].get("t", "從未用 credit 更新")
        print(f"{c['provider']} 點數 US${c['usd_left']}/{c['usd_total']}  到期 {c['expires']}  最後更新 {last}  {c.get('note', '')}")
elif cmd == "use":
    p = a[0] if a else sys.exit("usage: use <claude|codex>")
    cs = sorted((c for c in d["cards"] if c["provider"] == p and live(c)), key=lambda c: ts(c["expires"]))
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
elif cmd == "credit":
    if len(a) < 2: sys.exit("usage: credit <provider> <USD 餘額>")
    try: v = float(a[1])
    except ValueError: sys.exit(f"餘額不是數字：{a[1]}")
    if v < 0: sys.exit("餘額不能是負數")
    cs = sorted((c for c in d.get("credits", []) if c.get("provider") == a[0] and ts(c["expires"]) > now), key=lambda c: ts(c["expires"]))
    if not cs: sys.exit(f"沒有未過期的 {a[0]} 點數；先在 quota-reserves.json 的 credits 加一筆（provider、usd_left、usd_total、expires）")
    c = cs[0]; c["usd_left"] = v; c["usd_total"] = max(float(c.get("usd_total") or 0), v)
    c.setdefault("log", []).append({"t": datetime.now().astimezone().isoformat(timespec="seconds"), "usd_left": v})
    c["log"] = c["log"][-100:]
    save(); print(f"已更新 {a[0]} 點數餘額 US${v:g}（到期 {c['expires']}，共 {len(c['log'])} 筆紀錄）")
else: sys.exit(f"未知指令 {cmd}")
PY
