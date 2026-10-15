#!/usr/bin/env python3
"""analyze.py — 讀 history.jsonl，輸出規則校準報告（Markdown）。只用標準庫、不連網、不改任何門檻。

  bin/analyze.py <history.jsonl>          讀本機檔案
  bin/analyze.py --gh-pages               讀本地 git 物件 origin/gh-pages:data/history.jsonl（不 fetch；要最新先自己 git fetch origin gh-pages）
  選項：-o <路徑> 報告寫到該檔（預設 stdout）；--json 改輸出統計 JSON（測試用）；--ref <git ref> 搭配 --gh-pages 換分支

history 每列：t, mode, route, hub, c5, c7, cs, x5, x7, xs（c=Claude、x=Codex；5/7=5h/7d 已用%；s=週盈餘＝週期已過% − 週已用%），
2026-10-15 起另有 override、card（舊列沒有，相關統計略過舊列）。缺必要欄位或格式壞掉的單列略過並計數。
門檻現值從 bin/pick-model.sh、bin/quota-mode.sh 的預設值宣告行解析（唯讀），報告只建議方向、不改值。
時間以本機時區顯示（TZ 環境變數可改）。
"""
import argparse, json, os, re, subprocess, sys, time
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEEK, DAY, HOUR = 7 * 86400, 86400, 3600
GAP = 2 * HOUR          # 相鄰兩列超過這個間隔視為資料空窗，空窗不計入時間占比
LAST_W = 1800           # 最後一列代表的時間（推送間隔）
NEAR = 5                # 「門檻附近」＝ ±5
MIN_DAYS = 3            # 少於這麼多天標「樣本不足」
REQUIRED = ("t", "mode", "route", "hub", "c5", "c7", "cs", "x5", "x7", "xs")
PROV = {"claude": ("c5", "c7", "cs"), "codex": ("x5", "x7", "xs")}
NAME = {"claude": "Claude", "codex": "Codex"}


def thresholds():
    """解析 pick-model.sh／quota-mode.sh 的 `NAME="${ENV:-值}"` 預設值宣告行。"""
    out = {}
    for f in ("pick-model.sh", "quota-mode.sh"):
        try:
            for line in open(os.path.join(ROOT, "bin", f), encoding="utf-8"):
                m = re.match(r'^([A-Z_0-9]+)="\$\{[A-Z_0-9]+:-([0-9.]+)\}"\s*$', line)
                if m: out[m.group(1)] = float(m.group(2))
        except OSError: pass
    return out


def read_source(a):
    if a.gh_pages:
        r = subprocess.run(["git", "-C", ROOT, "show", f"{a.ref}:data/history.jsonl"], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"讀不到 {a.ref}:data/history.jsonl（{r.stderr.strip()}）；先跑 git fetch origin gh-pages")
        return r.stdout, f"{a.ref}:data/history.jsonl"
    with open(a.path, encoding="utf-8") as fh:
        return fh.read(), a.path


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def parse(text):
    rows, skipped, why = [], 0, Counter()
    for line in text.splitlines():
        if not line.strip(): continue
        try: r = json.loads(line)
        except ValueError: skipped += 1; why["不是 JSON"] += 1; continue
        if not isinstance(r, dict) or any(k not in r for k in REQUIRED): skipped += 1; why["缺必要欄位"] += 1; continue
        if not num(r["t"]) or not (num(r["mode"]) or str(r["mode"]).isdigit()) or not all(r[k] is None or num(r[k]) for k in REQUIRED[4:]):
            skipped += 1; why["欄位型別錯誤"] += 1; continue
        r["mode"] = int(r["mode"])
        rows.append(r)
    rows.sort(key=lambda r: r["t"])
    dedup = []
    for r in rows:                       # 同一秒重複推送只留最後一筆
        if dedup and dedup[-1]["t"] == r["t"]: dedup[-1] = r
        else: dedup.append(r)
    return dedup, skipped, dict(why)


def weights(rows):
    w = []
    for i, r in enumerate(rows):
        w.append(LAST_W if i == len(rows) - 1 else min(rows[i + 1]["t"] - r["t"], GAP))
    return w


def lt(t): return time.localtime(t)
def fmt_t(t): return time.strftime("%m/%d %H:%M", lt(t))
def day_key(t): return time.strftime("%Y-%m-%d", lt(t))
def pct(a, b): return round(100 * a / b, 1) if b else 0.0


def share(rows, w, key):
    acc, tot = Counter(), sum(w)
    for r, x in zip(rows, w): acc[str(r[key])] += x
    return {k: pct(v, tot) for k, v in sorted(acc.items(), key=lambda kv: -kv[1])}


def switches(rows):
    per_day, hub_per_day, flaps, events = Counter(), Counter(), 0, []
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        if a["mode"] != b["mode"]:
            per_day[day_key(b["t"])] += 1; events.append((b["t"], a["mode"], b["mode"]))
        if a["hub"] != b["hub"]: hub_per_day[day_key(b["t"])] += 1
    for j in range(1, len(events)):     # A→B 後 3 小時內又 B→A ＝ 來回跳動
        t0, a0, b0 = events[j - 1]; t1, a1, b1 = events[j]
        if a1 == b0 and b1 == a0 and t1 - t0 <= 3 * HOUR: flaps += 1
    days = sorted({day_key(r["t"]) for r in rows})
    return {"per_day": {d: per_day.get(d, 0) for d in days}, "max_per_day": max(per_day.values(), default=0),
            "hub_per_day": {d: hub_per_day.get(d, 0) for d in days}, "hub_max_per_day": max(hub_per_day.values(), default=0), "flaps": flaps}


def cycles(rows, p):
    """偵測週 reset：週期已過%（＝盈餘＋已用）倒退 → 新週期；照原排程到點＝自然結束，提早＝非排程 reset（週期重開）；
    週期沒倒退但已用驟降 ≥10 → 非排程 reset（只歸零用量，例如用卷或供應商重置）。"""
    _, u7, s7 = PROV[p]
    pts = [(r["t"], r[u7], r[s7] + r[u7]) for r in rows if r[u7] is not None and r[s7] is not None]
    ends, unsched = [], []
    for (t0, u0, e0), (t1, u1, e1) in zip(pts, pts[1:]):
        due = t0 + (100 - e0) / 100 * WEEK          # 前一列推算的自然 reset 時間
        if e1 < e0 - 5:
            if t1 >= due - HOUR:
                ends.append({"end_t": round(due), "left": round(100 - u0, 1), "last_gap_h": round(max(0, due - t0) / HOUR, 1)})
            else:
                unsched.append({"t": t1, "kind": "週期重開", "used_before": u0, "used_after": u1, "elapsed_before": round(e0, 1), "due_t": round(due)})
        elif u0 - u1 >= 10:
            unsched.append({"t": t1, "kind": "只歸零用量", "used_before": u0, "used_after": u1, "elapsed_before": round(e0, 1), "due_t": round(due)})
    cur = None
    if pts:
        t, u, e = pts[-1]
        cur = {"elapsed": round(e, 1), "used": u, "projected_left": round(100 - u / e * 100, 1) if e >= 10 else None}
    return {"ends": ends, "unscheduled": unsched, "current": cur}


def boundary(rows, w, th):
    acc, tot = Counter(), Counter()
    d, smin, ramp, lmin = th.get("DEFICIT", 15), th.get("SURPLUS_MIN", 15), th.get("RAMP", 50), th.get("LEFT_MIN", 15)
    xd, xr = th.get("CODEX_DEFICIT", 25), th.get("CODEX_RICH", 15)
    for r, x in zip(rows, w):
        if r["cs"] is not None and r["c7"] is not None:
            s, e, left = r["cs"], r["cs"] + r["c7"], 100 - r["c7"]
            tot["claude"] += x
            if abs(s + d) <= NEAR: acc["claude_tight"] += x
            if abs(s - smin * min(1.0, e / ramp)) <= NEAR: acc["claude_rich"] += x
            if abs(left - lmin) <= NEAR: acc["claude_left_min"] += x
        if r["xs"] is not None and r["x7"] is not None:
            s = r["xs"]; tot["codex"] += x
            if abs(s + xd) <= NEAR: acc["codex_tight"] += x
            if abs(s - xr) <= NEAR: acc["codex_rich"] += x
            if abs(s) <= NEAR: acc["codex_lean"] += x
    return {k: pct(acc[k], tot[k.split("_")[0]]) for k in
            ("claude_tight", "claude_rich", "claude_left_min", "codex_tight", "codex_rich", "codex_lean")}


def five_hour(rows, w):
    out = {}
    for p, (u5, _, _) in PROV.items():
        res = {}
        for thr in (70, 90):
            starts, hours, prev = [], 0.0, None
            for r, x in zip(rows, w):
                v = r[u5]
                if v is None: prev = None; continue
                if v >= thr:
                    hours += x / HOUR
                    if prev is None or prev < thr: starts.append(r["t"])
                prev = v
            slots = Counter(f"{lt(t).tm_hour // 6 * 6:02d}-{lt(t).tm_hour // 6 * 6 + 6:02d}" for t in starts)
            res[str(thr)] = {"episodes": len(starts), "hours": round(hours, 1), "slots": dict(sorted(slots.items()))}
        out[p] = res
    return out


def episodes(rows, w, key):
    """連續相同、非 '-' 的值算一段；缺欄的舊列略過。"""
    have = [(r, x) for r, x in zip(rows, w) if key in r]
    eps, cur = [], None
    for r, x in have:
        v = r[key] if r[key] not in (None, "") else "-"
        if v != "-" and cur and cur["value"] == v: cur["hours"] += x / HOUR
        elif v != "-":
            cur = {"value": v, "start": r["t"], "hours": x / HOUR}; eps.append(cur)
        else: cur = None
    by = defaultdict(lambda: {"episodes": 0, "hours": 0.0})
    for e in eps:
        by[e["value"]]["episodes"] += 1; by[e["value"]]["hours"] += e["hours"]
    for e in eps: e["hours"] = round(e["hours"], 1)
    return {"rows_with_field": len(have), "rows_without_field": len(rows) - len(have),
            "values": {k: {"episodes": v["episodes"], "hours": round(v["hours"], 1)} for k, v in sorted(by.items())}, "episodes": eps}


def suggest(st, th):
    """依統計列出可能要調的門檻（只建議方向）。每項：threshold, current, direction, reason。"""
    out, days = [], max(st["days"], 1e-9)
    def add(name, direction, reason): out.append({"threshold": name, "current": th.get(name), "direction": direction, "reason": reason})
    for p in ("claude", "codex"):
        ends = st["cycles"][p]["ends"]
        if ends:
            avg = sum(e["left"] for e in ends) / len(ends)
            rich = st["rich_share"][p]
            if avg >= 20 and rich >= 80:
                add("WEEKEND", "↓", f"{NAME[p]} 週期結束時平均剩 {avg:.0f}%，但 {rich:.0f}% 時間已判 rich：rich 門檻不是瓶頸（工作量不足），只能讓週末清倉更早觸發。")
            elif avg >= 20:
                if p == "claude":
                    add("SURPLUS_MIN", "↓", f"Claude 週期自然結束時平均還剩 {avg:.0f}%（浪費）：降低 rich 門檻，讓更多時間判 rich、工作留在 Claude。")
                    add("RAMP", "↓", f"同上：週初 rich 門檻爬升期縮短，週初就較容易判 rich。")
                else:
                    add("CODEX_RICH", "↓", f"Codex 週期自然結束時平均還剩 {avg:.0f}%（浪費）：降低 rich 門檻，更早傾向派工。")
                add("WEEKEND", "↓", f"{NAME[p]} 週期結束時平均剩 {avg:.0f}%：降低週末清倉的盈餘門檻，讓清倉更早觸發。")
            if min(e["left"] for e in ends) <= 3:
                if p == "claude":
                    add("DEFICIT", "↓", "Claude 曾在週期結束前見底（剩 ≤3%）：調小 DEFICIT，盈餘還沒掉那麼深就判吃緊，更早改 Sonnet／派工。")
                    add("LEFT_MIN", "↑", "同上：週剩量的保底提高，更早判吃緊。")
                else:
                    add("CODEX_DEFICIT", "↓", "Codex 曾在週期結束前見底（剩 ≤3%）：調小 CODEX_DEFICIT，更早判吃緊、停止派工。")
                    add("LEFT_TIGHT", "↑", "同上：週剩量的保底提高（兩邊共用）。")
    sw = st["switches"]
    if sw["max_per_day"] >= 6 or sw["flaps"] >= 3:
        b = st["boundary"]; worst = max(b, key=b.get)
        add("HYST", "↑", f"模式單日最多切換 {sw['max_per_day']} 次、來回跳動 {sw['flaps']} 次（主控單日最多切 {sw['hub_max_per_day']} 次）：加大遲滯。"
            f"停留最久的邊界是 {worst}（{b[worst]}% 時間在 ±{NEAR} 內）；quota-mode.sh 的矩陣邊界沒有遲滯，見後續建議。")
    for p, low in (("claude", "LOW_5H"), ("codex", "LOW_5H")):
        e90 = st["five_hour"][p]["90"]["episodes"]
        if e90 / days >= 1:
            add(low, "↑", f"{NAME[p]} 5h 用到 90% 以上平均每天 {e90 / days:.1f} 次：提高偏低門檻，更早把新任務轉到另一邊。")
            add("BLOCK_5H", "↑", f"同上：若常在 5h 見底才暫停，可提高暫停門檻。")
    card = st["card"]
    if card["rows_with_field"] and not card["values"]:
        low_ends = [e for p in ("claude", "codex") for e in st["cycles"][p]["ends"] if e["left"] <= th.get("CARD_USE_LEFT", 10)]
        if low_ends:
            add("CARD_USE_LEFT", "↑（若當時有卷）", f"有 {len(low_ends)} 次週期結束時剩 ≤{th.get('CARD_USE_LEFT', 10):.0f}% 但期間沒有用卷建議；若手上有卷，可提高門檻更早提示。")
    seen, uniq = set(), []
    for s in out:                          # 同一門檻只留第一條理由
        if s["threshold"] not in seen: seen.add(s["threshold"]); uniq.append(s)
    return uniq


def analyze(text, source):
    th = thresholds()
    rows, skipped, why = parse(text)
    if not rows:
        return {"source": source, "rows": 0, "skipped": skipped, "skip_reasons": why, "days": 0, "insufficient": True, "thresholds": th}
    w = weights(rows)
    span = rows[-1]["t"] - rows[0]["t"]
    gaps = [(a["t"], b["t"]) for a, b in zip(rows, rows[1:]) if b["t"] - a["t"] > GAP]
    st = {"source": source, "rows": len(rows), "skipped": skipped, "skip_reasons": why,
          "first_t": rows[0]["t"], "last_t": rows[-1]["t"], "days": round(span / DAY, 2), "insufficient": span < MIN_DAYS * DAY,
          "gaps": [{"from": a, "to": b, "hours": round((b - a) / HOUR, 1)} for a, b in gaps],
          "share": {k: share(rows, w, k) for k in ("mode", "route", "hub")},
          "switches": switches(rows),
          "cycles": {p: cycles(rows, p) for p in PROV},
          "boundary": boundary(rows, w, th),
          "five_hour": five_hour(rows, w),
          "override": episodes(rows, w, "override"),
          "card": episodes(rows, w, "card"),
          # 矩陣列／欄＝ rich 的模式：Claude rich ＝ M1–4，Codex rich ＝ M1、M5、M9
          "rich_share": {"claude": round(sum(x for r, x in zip(rows, w) if r["mode"] in (1, 2, 3, 4)) * 100 / sum(w), 1),
                         "codex": round(sum(x for r, x in zip(rows, w) if r["mode"] in (1, 5, 9)) * 100 / sum(w), 1)},
          "thresholds": th}
    st["suggestions"] = suggest(st, th)
    return st


def table(head, rows):
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "---|" * len(head)] + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])


def report(st):
    L = ["# quota-pilot 規則校準報告", ""]
    if st["insufficient"]:
        L += [f"> ⚠️ **樣本不足，僅供參考**：資料只涵蓋 {st['days']:.1f} 天（少於 {MIN_DAYS} 天），以下數字與建議不宜直接用來調門檻。", ""]
    if not st["rows"]:
        L += [f"來源 `{st['source']}` 沒有可用的列（略過 {st['skipped']} 列）。"]
        return "\n".join(L) + "\n"
    tz = time.strftime("%Z", lt(st["last_t"]))
    L += [f"- 來源：`{st['source']}`；{st['rows']} 列（略過 {st['skipped']} 列{('：' + '、'.join(f'{k} {v}' for k, v in st['skip_reasons'].items())) if st['skipped'] else ''}）",
          f"- 期間：{fmt_t(st['first_t'])} → {fmt_t(st['last_t'])}（{tz}），共 {st['days']:.1f} 天"
          + (f"；資料空窗 {len(st['gaps'])} 段、合計 {sum(g['hours'] for g in st['gaps']):.1f} 小時（> {GAP // HOUR}h 未推送，不計入占比）" if st["gaps"] else ""), ""]

    L += ["## 時間占比", ""]
    for k, label in (("mode", "模式"), ("route", "route"), ("hub", "主控")):
        L += [f"- {label}：" + "、".join(f"{('M' + v) if k == 'mode' else v} {p}%" for v, p in st["share"][k].items())]
    sw = st["switches"]
    L += ["", f"**模式切換**：單日最多 {sw['max_per_day']} 次、來回跳動（3h 內 A→B→A）{sw['flaps']} 次；主控單日最多切換 {sw['hub_max_per_day']} 次。", "",
          table(["日期", "模式切換", "主控切換"], [(d, n, sw["hub_per_day"][d]) for d, n in sw["per_day"].items()]), ""]

    L += ["## 週期結束時剩多少", "", "自然結束＝照原排程到點 reset；非排程 reset（供應商主動重置、用卷）不算浪費，另列於下。", ""]
    rows = []
    for p in PROV:
        for e in st["cycles"][p]["ends"]:
            tag = "浪費" if e["left"] >= 20 else "見底" if e["left"] <= 3 else "—"
            note = f"最後讀數距結束 {e['last_gap_h']}h，實際剩量可能更少" if e["last_gap_h"] > 6 else ""
            rows.append((NAME[p], fmt_t(e["end_t"]), f"{e['left']:.0f}%", tag, note))
    L += [table(["", "週期結束", "剩", "判讀", "備註"], rows) if rows else "（期間內沒有自然結束的週期）", ""]
    for p in PROV:
        c = st["cycles"][p]["current"]
        if c:
            pl = c["projected_left"]
            L += [f"- {NAME[p]} 目前週期：已過 {c['elapsed']:.0f}%、已用 {c['used']:.0f}%" + (
                "" if pl is None else "，照目前速度會在週期結束前見底" if pl <= 0 else f"，照目前速度結束時約剩 {pl:.0f}%")]
    L += ["", "### 非排程 reset", ""]
    rows = [(NAME[p], fmt_t(u["t"]), u["kind"], f"{u['used_before']:.0f}% → {u['used_after']:.0f}%", f"{u['elapsed_before']:.0f}%", fmt_t(u["due_t"]))
            for p in PROV for u in st["cycles"][p]["unscheduled"]]
    L += [table(["", "時間", "類型", "週已用", "當時週期已過", "原排程 reset"], rows) if rows else "（沒有偵測到）",
          "", f"Claude {len(st['cycles']['claude']['unscheduled'])} 次、Codex {len(st['cycles']['codex']['unscheduled'])} 次。", ""]

    b, th = st["boundary"], st["thresholds"]
    L += ["## 週盈餘在門檻附近的時間（±5）", "",
          table(["邊界", "門檻", "時間占比"], [
              ("Claude 吃緊（盈餘 ≤ −DEFICIT）", f"−{th.get('DEFICIT', 15):.0f}", f"{b['claude_tight']}%"),
              ("Claude 充裕（盈餘 ≥ SURPLUS_MIN×爬升）", f"{th.get('SURPLUS_MIN', 15):.0f}（RAMP {th.get('RAMP', 50):.0f}）", f"{b['claude_rich']}%"),
              ("Claude 週剩 < LEFT_MIN", f"{th.get('LEFT_MIN', 15):.0f}", f"{b['claude_left_min']}%"),
              ("Codex 吃緊（盈餘 ≤ −CODEX_DEFICIT）", f"−{th.get('CODEX_DEFICIT', 25):.0f}", f"{b['codex_tight']}%"),
              ("Codex 充裕（盈餘 ≥ CODEX_RICH）", f"{th.get('CODEX_RICH', 15):.0f}", f"{b['codex_rich']}%"),
              ("Codex 超速（盈餘 < 0）", "0", f"{b['codex_lean']}%")]), ""]

    L += ["## 5h 用量", "", table(["", "≥70% 次數", "≥70% 時數", "≥90% 次數", "≥90% 時數", "≥90% 發生時段"],
          [(NAME[p], v["70"]["episodes"], v["70"]["hours"], v["90"]["episodes"], v["90"]["hours"], "、".join(f"{k} {n}" for k, n in v["90"]["slots"].items()) or "—")
           for p, v in st["five_hour"].items()]), ""]
    for key, label in (("override", "override（5h 覆寫／週末清倉）"), ("card", "card（用卷建議）")):
        o = st[key]
        L += [f"## {label}", ""]
        if not o["rows_with_field"]:
            L += [f"（所有列都沒有 {key} 欄位：2026-10-15 前的舊格式）", ""]; continue
        L += [f"有 {key} 欄位的列 {o['rows_with_field']}、舊列略過 {o['rows_without_field']}。", ""]
        if not o["values"]: L += ["（期間內沒有出現）", ""]; continue
        L += [table(["值", "次數", "合計時數"], [(k, v["episodes"], v["hours"]) for k, v in o["values"].items()]), ""]
        if key == "card": L += ["出現時間點：" + "、".join(f"{fmt_t(e['start'])} {e['value']}" for e in o["episodes"]), ""]

    L += ["## 建議", ""]
    if st["insufficient"]: L += ["> 樣本不足：以下只是方向提示，累積滿 7 天（最好跨過一次週期結束）再決定。", ""]
    if st["suggestions"]:
        L += ["只列方向、不改值；改門檻時請見 README「校準流程」的同步清單。", "",
              table(["門檻", "現值", "方向", "理由"], [(s["threshold"], "?" if s["current"] is None else f"{s['current']:g}", s["direction"], s["reason"]) for s in st["suggestions"]])]
    else:
        L += ["目前數據沒有明顯需要調整的門檻。"]
    uc = len(st["cycles"]["codex"]["unscheduled"])
    if uc: L += ["", f"- 註：Codex 有 {uc} 次非排程 reset，自然結束的週期樣本變少；別只憑一兩個週期調 Codex 門檻。"]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", nargs="?")
    ap.add_argument("--gh-pages", action="store_true")
    ap.add_argument("--ref", default="origin/gh-pages")
    ap.add_argument("-o", "--output")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if bool(a.path) == a.gh_pages: ap.error("給 history.jsonl 路徑，或用 --gh-pages（二擇一）")
    text, source = read_source(a)
    st = analyze(text, source)
    out = json.dumps(st, ensure_ascii=False, indent=1) + "\n" if a.json else report(st)
    if a.output:
        with open(a.output, "w", encoding="utf-8") as fh: fh.write(out)
    else:
        sys.stdout.write(out)


if __name__ == "__main__":
    main()
