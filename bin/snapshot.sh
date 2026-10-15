#!/usr/bin/env bash
# snapshot.sh — 把當下額度狀態輸出成儀表板用的 JSON（stdout）。不耗 LLM token。
# 只含：各視窗用量 %／reset 時間、週盈餘、quota-mode 判定與依據、重置卷到期日、點數餘額。不含路徑、帳號、對話內容。
# 來源：~/.claude/state/rate_limits.json（Claude status line 落地）、codex-quota.sh --cached、quota-reserves.json。
d="$(cd "$(dirname "$0")" && pwd)"
STATE="${QP_STATE:-$HOME/.claude/state/rate_limits.json}"
RES="${QUOTA_RESERVES:-$HOME/.claude/state/quota-reserves.json}"
tsv="$("$d/codex-quota.sh" --cached 2>/dev/null)"
mode="$("$d/quota-mode.sh" --state "$STATE" --reserves "$RES" ${tsv:+--codex-tsv "$tsv"} --explain 2>"${TMPDIR:-/tmp}/qp-explain.$$")"
explain="$(cat "${TMPDIR:-/tmp}/qp-explain.$$")"; rm -f "${TMPDIR:-/tmp}/qp-explain.$$"
python3 -I - "$STATE" "$RES" "$tsv" "$mode" "$explain" <<'PY'
import json, sys, time
state, res, tsv, mode, explain = sys.argv[1:6]
now = time.time(); WEEK = 7 * 86400
def win(used, reset):
    used, reset = float(used), float(reset or 0)
    if reset and reset <= now: used = 0.0  # 讀數之後已 reset
    return {"used": used, "resets_at": reset or None}
def surplus(w):
    r = w["resets_at"]
    if not r: return None
    while r <= now: r += WEEK
    return round(100 * (1 - (r - now) / WEEK) - w["used"], 1)
out = {"generated_at": round(now), "mode": dict(kv.split("=", 1) for kv in mode.split()), "explain": explain.splitlines()}
try:
    s = json.load(open(state))
    c = {"five": win(s["five_hour_used_pct"], s.get("five_hour_resets_at")), "week": win(s["seven_day_used_pct"], s["seven_day_resets_at"]), "updated_at": s.get("updated_epoch")}
    c["surplus"] = surplus(c["week"]); out["claude"] = c
except Exception: out["claude"] = None
f = tsv.split()
if len(f) >= 4:
    x = {"five": win(f[0], f[2]), "week": win(f[1], f[3])}; x["surplus"] = surplus(x["week"]); out["codex"] = x
else: out["codex"] = None
try: r = json.load(open(res))
except Exception: r = {}
out["cards"] = [{k: c.get(k) for k in ("provider", "expires", "used_at")} for c in r.get("cards", [])]
out["credits"] = [{k: c.get(k) for k in ("provider", "usd_left", "usd_total", "expires")} for c in r.get("credits", [])]
print(json.dumps(out, ensure_ascii=False, indent=1))
PY
