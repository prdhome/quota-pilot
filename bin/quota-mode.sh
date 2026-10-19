#!/usr/bin/env bash
# quota-mode.sh — Claude＋Codex 額度 → 調度模式（ROUTER.md「額度調節」；2026-10-15 矩陣版）。不耗 Claude token。
# 輸出一行：mode=<1-12> hub=<opus|sonnet> route=<…> subagent=<opus|sonnet> claude=<rich|ok|tight> codex=<rich|ok|lean|tight|unknown> override=<…> card=<…>
#   7d 決定模式（Claude 3 級 × Codex 4 級 = 12 格），5h 只做暫時覆寫。判斷順序：
#   1. 任一邊 5h 剩 < BLOCK_5H → 該邊暫停（override=claude5h|codex5h|both5h）
#   2. 7d 吃緊 → 矩陣 ④⑧⑨–⑫
#   3. 5h 剩 < LOW_5H → 新任務暫轉另一邊（override=claude5h-low|codex5h-low；Codex lean 時不轉給它）
#   4. 其餘照矩陣；5. 週末清倉：某邊 7d 在 24h 內 reset 且盈餘 ≥ WEEKEND → 放寬那一邊（override=weekend-*）
#   route：delegate 傾向派工｜cost 照成本判準｜direct 傾向直做｜no-codex 不派 Codex｜small-only 只直做小任務、大的等 reset｜hold 非急件延後
#   Claude：rich = 週盈餘達 pick-model.sh 門檻（只看 7d；5h 交給覆寫層，hub 欄才另看 5h）；tight = 週盈餘 ≤ −CLAUDE_DEFICIT 或週剩 < LEFT_TIGHT；其餘 ok。
#   Codex ：tight = 週剩 < LEFT_TIGHT 或週盈餘 ≤ −CODEX_DEFICIT；rich = 週盈餘 ≥ CODEX_RICH；lean = 週盈餘 < 0；其餘 ok；讀不到 = unknown（矩陣當 lean：不因額度不明而把工作推給 Codex；2026-10-15）。
#   subagent（只給非視覺 subagent；視覺建置／frontend-ux 固定 opus 不看此欄）：預設 sonnet，override=weekend-claude|weekend-both 才 opus（2026-10-20）。
#   重置卷（bin/quota-reserve.sh，~/.claude/state/quota-reserves.json）：該邊有未用、未過期的卷 → lean／tight 視同 ok（hub 不降 sonnet）；≥2 張 → ok／lean 視同 rich；
#   card 欄提示用卷：<邊>:use = 週剩 ≤ CARD_USE_LEFT 且自然 reset > 24h；<邊>:expiring = 最早到期卷 48h 內到期、週已用 ≥ 50% 且自然 reset > 24h。用卷由使用者手動按，按完跑 `quota-reserve.sh use <邊>`。
# `--detail`：第一行不變，另印第二行 `detail: …`（raw＝未計卷的原始級別、policy＝含卷後；fresh＝fresh|stale-partial|stale|missing；
#   left5／left7／surplus／reset_h；proj7＝照目前週速率到 reset 時的預估週用量%；runway_h＝照週速率用完週額度的小時數；cards＝未用卷數）。
#   Claude 讀不到時 policy 仍是 ok（舊行為），raw=unknown 提醒別當充足。
# `--explain` 附依據到 stderr。測試用：`--codex-tsv "<5h> <7d> <5h_reset> <7d_reset>"`、`--now EPOCH`、其餘參數（--state、--current）轉給 pick-model.sh。
LEFT_TIGHT="${LEFT_TIGHT:-15}"
CLAUDE_DEFICIT="${CLAUDE_DEFICIT:-15}"
CODEX_RICH="${CODEX_RICH:-15}"
CODEX_DEFICIT="${CODEX_DEFICIT:-25}"
BLOCK_5H="${BLOCK_5H:-10}"
LOW_5H="${LOW_5H:-30}"
WEEKEND="${WEEKEND:-20}"
CARD_USE_LEFT="${CARD_USE_LEFT:-10}"
RES="${QUOTA_RESERVES:-$HOME/.claude/state/quota-reserves.json}"
d="$(cd "$(dirname "$0")" && pwd)"
explain=0; detail=0; tsv=""; now=""; pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=1 ;;
    --detail) detail=1 ;;
    --codex-tsv) tsv="$2"; shift ;;
    --reserves) RES="$2"; shift ;;
    --now) now="$2"; pass+=(--now "$2"); shift ;;
    *) pass+=("$1") ;;
  esac; shift
done
hub_why=$(QUOTA_RESERVES="$RES" "$d/pick-model.sh" --explain "${pass[@]}" 2>&1 >/dev/null)
hubline=$(QUOTA_RESERVES="$RES" "$d/pick-model.sh" --detail "${pass[@]}" 2>/dev/null)
[ -n "$tsv" ] || tsv=$("$d/codex-quota.sh" --cached 2>/dev/null)
python3 -I - "$hubline" "$hub_why" "$tsv" "$explain" "$now" "$LEFT_TIGHT" "$CLAUDE_DEFICIT" "$CODEX_RICH" "$CODEX_DEFICIT" "$BLOCK_5H" "$LOW_5H" "$WEEKEND" "$RES" "$CARD_USE_LEFT" "$detail" <<'PY'
import json, sys, time
from datetime import datetime
hubline, hub_why, tsv, explain, now = sys.argv[1:6]
left_tight, c_def, x_rich, x_def, block, low, weekend = map(float, sys.argv[6:13])
res_file, card_left, detail = sys.argv[13], float(sys.argv[14]), sys.argv[15]
now = float(now) if now else time.time()
DAY, WEEK = 86400, 7 * 86400
hp = hubline.split(); hub = hp[0] if hp else "sonnet"
c = dict(zip(("surplus", "left5", "left7", "r5", "r7", "week_rich", "age"), map(float, hp[1:8]))) if len(hp) >= 7 else None
claude = "rich" if c and c["week_rich"] else "tight" if c and (c["surplus"] <= -c_def or c["left7"] < left_tight) else "ok"
f = tsv.split(); x = None
if len(f) >= 4:
    u5, u7, r5, r7 = map(float, f[:4])
    if r5 <= now: u5 = 0
    while r7 <= now: r7, u7 = r7 + WEEK, 0
    x = {"surplus": 100 * (1 - (r7 - now) / WEEK) - u7, "left5": 100 - u5, "left7": 100 - u7, "r5": r5, "r7": r7}
    codex = "tight" if x["left7"] < left_tight or x["surplus"] <= -x_def else "rich" if x["surplus"] >= x_rich else "lean" if x["surplus"] < 0 else "ok"
else:
    codex = "unknown"
try: cards = json.load(open(res_file)).get("cards", [])
except Exception: cards = []
def live(p):
    out = []
    for k in cards:
        try: e = datetime.fromisoformat(k["expires"]).timestamp()
        except Exception: continue
        if k.get("provider") == p and not k.get("used_at") and e > now: out.append(e)
    return sorted(out)
card_notes, card = [], []
def card_check(p, s, tier):
    exp = live(p)
    if not exp or not s: return tier
    if s["r7"] - now > DAY:
        if s["left7"] <= card_left: card.append(f"{p}:use")
        elif exp[0] - now <= 2 * DAY and s["left7"] <= 50: card.append(f"{p}:expiring")
    new = "rich" if len(exp) >= 2 and tier in ("ok", "lean") else "ok" if tier in ("lean", "tight") else tier
    if new != tier: card_notes.append(f"{p} {tier} → {new}（有 {len(exp)} 張卷）")
    return new
claude_raw, codex_raw = (claude if c else "unknown"), codex
claude = card_check("claude", c, claude)
codex = card_check("codex", x, codex)
if hub == "sonnet" and claude != "tight" and live("claude"): hub = "opus"
M = {("rich", "rich"): (1, "delegate"), ("rich", "ok"): (2, "cost"), ("rich", "lean"): (3, "direct"), ("rich", "tight"): (4, "no-codex"),
     ("ok", "rich"): (5, "delegate"), ("ok", "ok"): (6, "cost"), ("ok", "lean"): (7, "cost"), ("ok", "tight"): (8, "small-only"),
     ("tight", "rich"): (9, "delegate"), ("tight", "ok"): (10, "delegate"), ("tight", "lean"): (11, "hold"), ("tight", "tight"): (12, "hold")}
mode, route = M[(claude, "lean" if codex == "unknown" else codex)]
c5 = c["left5"] if c else 100.0
x5 = x["left5"] if x else 100.0
c_up, x_up = claude != "tight", codex != "tight"
ov, notes = "-", []
def soon(r): return r and 0 < r - now <= 3600
if c5 < block or x5 < block:                                   # 1. 5h 快見底：該邊暫停
    if c5 < block and x5 < block: route, ov = "hold", "both5h"
    elif c5 < block: route, ov = ("delegate" if x_up else "hold"), "claude5h"
    else: route, ov = ("no-codex" if c_up else "hold"), "codex5h"
    if c and c5 < block and soon(c["r5"]): notes.append("Claude 5h 1 小時內 reset，可等")
    if x and x5 < block and soon(x["r5"]): notes.append("Codex 5h 1 小時內 reset，可等")
elif c5 < low and x5 >= low and codex in ("rich", "ok") and route in ("direct", "cost"):   # 3. 5h 偏低：暫轉另一邊（Codex 超速時不轉，維持原 route、放慢）
    route, ov = "delegate", "claude5h-low"
elif x5 < low and c5 >= low and c_up and route in ("delegate", "cost"):
    route, ov = "direct", "codex5h-low"
else:                                                          # 5. 週末清倉
    wc = bool(c and c["r7"] - now <= DAY and c["surplus"] >= weekend)
    wx = bool(x and x["r7"] - now <= DAY and x["surplus"] >= weekend)
    if wc and wx: ov = "weekend-both"; route = "cost" if route in ("delegate", "direct") else route
    elif wc: ov = "weekend-claude"; route = "direct" if route in ("cost", "delegate") else route
    elif wx: ov = "weekend-codex"; route = "delegate" if route in ("cost", "direct") else route
subagent = "opus" if ov in ("weekend-claude", "weekend-both") else "sonnet"   # 非視覺 subagent 預設 sonnet，Claude 週末清倉才 opus（2026-10-20）
if explain == "1":
    fmt = lambda s: f"5h left {s['left5']:.0f}% week left {s['left7']:.0f}% surplus {s['surplus']:.0f}" if s else "no data"
    print(f"claude: {claude} — {hub_why}\ncodex:  {codex} — {fmt(x)}\nmatrix: ({claude},{codex}) → mode {mode}; override {ov} → route {route}" + "".join("\nnote:   " + n for n in notes + card_notes), file=sys.stderr)
print(f"mode={mode} hub={hub} route={route} subagent={subagent} claude={claude} codex={codex} override={ov} card={','.join(card) or '-'}")
if detail == "1":
    def side(n, s, raw, pol, fresh):
        if not s: return f"{n}_raw={raw} {n}_policy={pol} {n}_fresh={fresh} {n}_cards={len(live(n))}"
        el = WEEK - (s["r7"] - now); used = 100 - s["left7"]
        rate = used / el if el > 3600 else None        # %/秒，週初不足 1h 不估
        proj = f"{used * WEEK / el:.0f}" if rate else "-"
        run = f"{s['left7'] / rate / 3600:.0f}" if rate and used > 0 else "-"
        return (f"{n}_raw={raw} {n}_policy={pol} {n}_fresh={fresh} {n}_left5={s['left5']:.0f} {n}_left7={s['left7']:.0f} "
                f"{n}_surplus={s['surplus']:.0f} {n}_reset_h={(s['r7'] - now) / 3600:.0f} {n}_proj7={proj} {n}_runway_h={run} {n}_cards={len(live(n))}")
    if not c: cf = "missing" if hub_why.startswith(("no state", "unreadable")) else "stale"
    else: cf = "stale-partial" if c.get("age", 0) > 6 * 3600 else "fresh"
    print("detail: " + side("claude", c, claude_raw, claude, cf) + " " + side("codex", x, codex_raw, codex, "fresh" if x else "missing"))
PY
