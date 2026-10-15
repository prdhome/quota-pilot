#!/usr/bin/env python3
"""產生 tests/fixtures/history/*.jsonl（bin/analyze.py 的假歷史）。結果固定（固定起點、無亂數），tests/analyze-test.sh 會重跑並比對。
  python3 tests/fixtures/history/gen.py [輸出目錄]   預設寫回本目錄

每列格式同 bin/publish.sh：t, mode, route, hub, c5, c7, cs, x5, x7, xs（＋新格式的 override, card）。
模式／route／主控用簡化版 quota-mode.sh 規則算（只為讓假資料像真的；analyze.py 不依賴這些推導）。
"""
import json, math, os, sys

T0 = 1791158400            # 2026-10-05 00:00 UTC
STEP, DAY, WEEK = 1800, 86400, 7 * 86400
M = {("rich", "rich"): (1, "delegate"), ("rich", "ok"): (2, "cost"), ("rich", "lean"): (3, "direct"), ("rich", "tight"): (4, "no-codex"),
     ("ok", "rich"): (5, "delegate"), ("ok", "ok"): (6, "cost"), ("ok", "lean"): (7, "cost"), ("ok", "tight"): (8, "small-only"),
     ("tight", "rich"): (9, "delegate"), ("tight", "ok"): (10, "delegate"), ("tight", "lean"): (11, "hold"), ("tight", "tight"): (12, "hold")}


def elapsed(t, starts):
    """週期已過%：starts 是週期開始時刻（排序好，第一個 ≤ T0）；最後一個之後每 7 天自動開新週期。提早重開＝多放一個開始時刻。"""
    s = max(x for x in starts if x <= t)
    return 100 * ((t - s) % WEEK) / WEEK


def due(reset):
    """只給「下一次自然 reset 時刻」時的週期開始時刻。"""
    return [reset - WEEK]


def sawtooth(t, peak):
    return round(peak * ((t - T0) % (5 * 3600) + STEP) / (5 * 3600))     # 每個 5h 視窗最後一列到 peak


def tiers(cs, c7, xs, x7):
    e = cs + c7
    c = "rich" if cs >= 15 * min(1, e / 50) else "tight" if cs <= -15 or 100 - c7 < 15 else "ok"
    x = "tight" if 100 - x7 < 15 or xs <= -25 else "rich" if xs >= 15 else "lean" if xs < 0 else "ok"
    return c, x


def row(t, c5, c7, ce, x5, x7, xe, extra=None):
    c7, x7 = round(min(100, max(0, c7)), 1), round(min(100, max(0, x7)), 1)
    cs, xs = round(ce - c7, 1), round(xe - x7, 1)
    c, x = tiers(cs, c7, xs, x7)
    mode, route = M[(c, x)]
    r = {"t": t, "mode": mode, "route": route, "hub": "sonnet" if c == "tight" else "opus",
         "c5": float(c5), "c7": float(c7), "cs": cs, "x5": float(x5), "x7": float(x7), "xs": xs}
    if extra: r.update(extra)
    return r


def series(days):
    return range(T0, T0 + int(days * DAY) + 1, STEP)


def stable_rich():
    """穩定充裕一週：兩邊用量都只有週期進度的 6 成，Claude／Codex 各自然結束一次（剩約 40%）。"""
    cr, xr = due(T0 + int(2.5 * DAY)), due(T0 + 4 * DAY)
    out = []
    for t in series(7):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        out.append(row(t, sawtooth(t, 60), 0.6 * ce, ce, sawtooth(t + 3600, 50), 0.6 * xe, xe))
    return out


def claude_overrun():
    """Claude 超速後見底：用量＝週期進度 ×1.25，第 4.6 天見底，第 6 天自然結束時剩 0；白天 5h 常衝到 96%。"""
    cr, xr = due(T0 + 6 * DAY), due(T0 + 3 * DAY)
    out = []
    for t in series(7):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        hour = (t // 3600) % 24
        out.append(row(t, sawtooth(t, 96 if 1 <= hour < 13 else 50), 1.25 * ce, ce, sawtooth(t, 40), 0.9 * xe, xe))
    return out


def flapping():
    """門檻附近反覆切換：Claude 盈餘在 −15（吃緊門檻）上下 ±4 擺盪，週期 3 小時。"""
    cr, xr = due(T0 + 5 * DAY), due(T0 + 6 * DAY)
    out = []
    for t in series(3):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        c7 = ce + 15 + 4 * math.sin(2 * math.pi * (t - T0) / (3 * 3600))
        out.append(row(t, sawtooth(t, 50), c7, ce, sawtooth(t, 40), 0.7 * xe, xe))
    return out


def waste():
    """週期 reset 前剩很多：前段照進度 9 成用，用到 6 成後停用 → 兩邊自然結束時都剩 40% 左右。"""
    cr, xr = due(T0 + 5 * DAY), due(T0 + 6 * DAY)
    out = []
    for t in series(7):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        out.append(row(t, sawtooth(t, 40), min(0.9 * ce, 60), ce, sawtooth(t, 40), min(0.9 * xe, 58), xe))
    return out


def codex_unscheduled():
    """Codex 非排程 reset：第 1.5 天週期被提早重開（用量歸零、reset 往後跳）；第 4 天又被歸零但週期不變（類似用卷）。Claude 正常、第 2 天自然結束。"""
    cr = due(T0 + 2 * DAY)
    early = T0 + int(1.5 * DAY)                  # 原排程 T0+5d，提早在 1.5 天重開 → 新週期到 early+7d
    xr = [T0 + 5 * DAY - WEEK, early]
    zero = T0 + 4 * DAY
    out = []
    for t in series(5):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        x7 = 1.1 * xe if t < early else 1.3 * xe if t < zero else 1.3 * (xe - elapsed(zero, xr))
        out.append(row(t, sawtooth(t, 50), 0.9 * ce, ce, sawtooth(t, 60), x7, xe))
    return out


def mixed_columns():
    """新舊欄位混合：前 2 天舊格式（無 override／card），後 2 天新格式；5h 偏高時有 override，兩段 card 建議；另插 3 列壞資料。"""
    cr, xr = due(T0 + 5 * DAY), due(T0 + 6 * DAY)
    out = []
    for t in series(4):
        ce, xe = elapsed(t, cr), elapsed(t, xr)
        c5 = sawtooth(t, 95)
        extra = None
        if t >= T0 + 2 * DAY:
            ov = "claude5h" if c5 >= 90 else "claude5h-low" if c5 >= 70 else "-"
            card = "codex:expiring" if T0 + int(2.5 * DAY) <= t < T0 + int(2.5 * DAY) + 3 * 3600 else \
                   "claude:use" if T0 + int(3.5 * DAY) <= t < T0 + int(3.5 * DAY) + 2 * 3600 else "-"
            extra = {"override": ov, "card": card}
        out.append(row(t, c5, 0.8 * ce, ce, sawtooth(t, 40), 0.8 * xe, xe, extra))
    return out


def short():
    """樣本不足：只有 1 天。"""
    cr, xr = due(T0 + 3 * DAY), due(T0 + 4 * DAY)
    return [row(t, sawtooth(t, 40), 0.7 * elapsed(t, cr), elapsed(t, cr), sawtooth(t, 40), 0.7 * elapsed(t, xr), elapsed(t, xr)) for t in series(1)]


BAD = ['not json at all', '{"t": 1791400000, "mode": 6, "route": "cost", "hub": "opus", "c5": 1, "c7": 2, "x5": 3, "x7": 4, "xs": 5}',
       '{"t": 1791400100, "mode": 6, "route": "cost", "hub": "opus", "c5": "high", "c7": 2, "cs": 1, "x5": 3, "x7": 4, "xs": 5}']
SCENARIOS = {"stable-rich": stable_rich, "claude-overrun": claude_overrun, "flapping": flapping, "waste": waste,
             "codex-unscheduled": codex_unscheduled, "mixed-columns": mixed_columns, "short": short}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    os.makedirs(out, exist_ok=True)
    for name, fn in SCENARIOS.items():
        lines = [json.dumps(r) for r in fn()]
        if name == "mixed-columns":
            for i, b in enumerate(BAD): lines.insert(40 + 30 * i, b)
        with open(os.path.join(out, name + ".jsonl"), "w") as fh: fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
