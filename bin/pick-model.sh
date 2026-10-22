#!/usr/bin/env bash
# pick-model.sh — 依 Claude 7d 額度選主控模型，輸出 opus 或 sonnet（`--explain` 附判斷依據到 stderr）。
# 2026-10-15 起「主控一律 Opus」（有加購用量當安全網）：只有 Claude 7d 吃緊才 sonnet——
#   吃緊 = 週盈餘（週期已過% − 週已用%）≤ −DEFICIT，或週剩 < LEFT_MIN。5h 不影響主控（交給 quota-mode.sh 覆寫層）。
# 吃緊但還有未用、未過期的 Claude 重置卷（~/.claude/state/quota-reserves.json，`QUOTA_RESERVES` 可改）→ 仍 opus（該用卷，不該降級；提示由 quota-mode.sh card 欄給）。
# 視窗已過 reset → 該視窗用量視為 0。資料過期（>6h 且 7d 未 reset；只有 5h reset 仍算過期）／缺檔 → opus（無法判斷吃緊時用預設）。
# `--current opus`：已在 Opus 時 DEFICIT 加 HYST（遲滯），避免在門檻附近來回建議切換。
# `--detail`：stdout 在模型後附 `<盈餘> <5h剩%> <週剩%> <5h_reset> <週reset> <週盈餘達 rich 門檻 1|0> <讀數秒齡>`（給 quota-mode.sh 的矩陣等級用；
#   rich 門檻 = SURPLUS_MIN × min(1, 週期已過% / RAMP)，週初較低）。讀不到資料時只印模型。
# 測試用：`--state FILE`、`--now EPOCH`。測試：tests/policy-test.sh。門檻同步：orchestrator mods/quota-monitor/hooks/lib.ts（orchestrator tests/quota-policy-test.sh 檢查）。
# `--effort`：中間檔（opus 且週盈餘未達 rich 門檻）在模型後附 ` low`，給包裝帶 `--effort low`（2026-10-22，bench 6 題 low 無失分、省 16–40%）。
# 用法：claude --model "$(bin/pick-model.sh)"
DEFICIT="${PICK_DEFICIT:-15}"
LEFT_MIN="${PICK_LEFT_MIN:-15}"
HYST="${PICK_HYST:-10}"
SURPLUS_MIN="${PICK_SURPLUS_MIN:-15}"
RAMP="${PICK_RAMP:-50}"
RES="${QUOTA_RESERVES:-$HOME/.claude/state/quota-reserves.json}"
f="$HOME/.claude/state/rate_limits.json"; now=""; cur=""; explain=0; detail=0; effort=0
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=1 ;;
    --detail) detail=1 ;;
    --effort) effort=1 ;;
    --state) f="$2"; shift ;;
    --now) now="$2"; shift ;;
    --current) cur="$2"; shift ;;
  esac; shift
done
[ -f "$f" ] || { [ $explain = 1 ] && echo "no state file → default opus" >&2; echo opus; exit 0; }
python3 -I - "$f" "$DEFICIT" "$LEFT_MIN" "$HYST" "$SURPLUS_MIN" "$RAMP" "$explain" "$now" "$cur" "$detail" "$RES" "$effort" <<'PY'
import json, sys, time
f, deficit, left_min, hyst, smin, ramp, explain, now, cur, detail, res, effort = sys.argv[1:13]
deficit, left_min, hyst, smin, ramp = map(float, (deficit, left_min, hyst, smin, ramp))
explain = explain == "1"
now = float(now) if now else time.time()
WEEK = 7 * 86400
def out(m, why, extra=""):
    if explain: print(why, file=sys.stderr)
    print(m + (" " + extra if detail == "1" and extra else "")); sys.exit(0)
try:
    d = json.load(open(f))
    week_reset, five_reset = float(d["seven_day_resets_at"]), float(d.get("five_hour_resets_at") or 0)
    week_used, five_used = float(d["seven_day_used_pct"]), float(d["five_hour_used_pct"])
except (KeyError, ValueError, TypeError, json.JSONDecodeError): out("opus", "unreadable state → default opus")
notes = []
if week_reset <= now:  # 週期已重置：用量歸零，reset 往後推到下一個週期
    while week_reset <= now: week_reset += WEEK
    week_used = 0; notes.append("7d reset since reading")
if five_reset and five_reset <= now:
    five_used = 0; notes.append("5h reset since reading")
age = now - d["updated_epoch"]
if age > 6 * 3600 and week_reset == float(d["seven_day_resets_at"]):  # 只有 5h reset 不代表 7d 讀數可信（2026-10-20）
    out("opus", f"stale {age/3600:.1f}h → default opus")
elapsed = 100 * (1 - (week_reset - now) / WEEK)
surplus = elapsed - week_used
week_left = 100 - week_used
dmax = deficit + (hyst if cur == "opus" else 0)
tight = surplus <= -dmax or week_left < left_min
rich_min = smin * min(1.0, elapsed / ramp)
why = f"week elapsed {elapsed:.0f}% used {week_used:.0f}% surplus {surplus:.0f} (tight ≤ -{dmax:.0f} or week left < {left_min:.0f}; rich ≥ {rich_min:.0f}); 5h left {100 - five_used:.0f}%"
if tight:
    try:
        from datetime import datetime
        if any(k.get("provider") == "claude" and not k.get("used_at") and datetime.fromisoformat(k["expires"]).timestamp() > now
               for k in json.load(open(res)).get("cards", [])):
            tight = False; notes.append("tight but Claude reset card available → opus")
    except Exception: pass
if notes: why += "; " + ", ".join(notes)
model = "sonnet" if tight else "opus"
if effort == "1" and model == "opus" and surplus < rich_min: model += " low"
out(model, why,
    f"{surplus:.1f} {100 - five_used:.1f} {week_left:.1f} {five_reset:.0f} {week_reset:.0f} {int(surplus >= rich_min)} {age:.0f}")
PY
