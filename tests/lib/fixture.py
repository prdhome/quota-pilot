#!/usr/bin/env python3
"""把 tests/fixtures/<情境>.json 換算成以「現在」為基準的假資料（規則測試、snapshot 測試、網頁冒煙測試與 bin/preview.sh 共用）。

情境檔的時間欄位都是相對秒數（*_in = 現在之後、*_ago = 現在之前），所以假資料不會隨日期過期。

  fixture.py state <情境> <輸出目錄>   寫 state/rate_limits.json、state/quota-reserves.json、state/codex.tsv（Codex 讀不到時為 "-"）
  fixture.py site  <情境> <輸出目錄>   state ＋ 複製 site/ ＋ 用 bin/snapshot.sh 產生 data/snapshot.json ＋ 合成 7 天 data/history.jsonl
                                       ＋ data/work.json（格式同 bin/work-stats.sh；情境的 "work" 欄覆寫預設值，設 null＝不產生）
  fixture.py list                       列出情境與說明

<情境> 可以是名稱（rich）或檔案路徑。不讀也不寫任何真實額度檔（HOME 指向輸出目錄內的空資料夾）。
"""
import json, math, os, shutil, subprocess, sys, time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIX = os.path.join(ROOT, "tests", "fixtures")


def load(name):
    path = name if name.endswith(".json") else os.path.join(FIX, name + ".json")
    with open(path) as fh:
        return json.load(fh)


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).astimezone().isoformat(timespec="seconds")


def write_state(sc, out, now):
    st = os.path.join(out, "state")
    os.makedirs(st, exist_ok=True)
    os.makedirs(os.path.join(out, "home"), exist_ok=True)
    c = sc.get("claude")
    if c:
        with open(os.path.join(st, "rate_limits.json"), "w") as fh:
            json.dump({"five_hour_used_pct": c["five_used"], "five_hour_resets_at": str(round(now + c["five_reset_in"])),
                       "seven_day_used_pct": c["week_used"], "seven_day_resets_at": str(round(now + c["week_reset_in"])),
                       "updated_epoch": round(now - c.get("updated_ago", 0))}, fh)
    x = sc.get("codex")
    tsv = "\t".join(str(v) for v in (x["five_used"], x["week_used"], round(now + x["five_reset_in"]), round(now + x["week_reset_in"]))) if x else "-"
    with open(os.path.join(st, "codex.tsv"), "w") as fh:
        fh.write(tsv + "\n")
    r = sc.get("reserves") or {}
    res = {"cards": [{"provider": k["provider"], "expires": iso(now + k["expires_in"]), "used_at": k.get("used_at")} for k in r.get("cards", [])],
           "credits": [{"provider": k["provider"], "usd_left": k["usd_left"], "usd_total": k["usd_total"], "expires": iso(now + k["expires_in"]),
                        "note": k.get("note", "")} for k in r.get("credits", [])]}
    with open(os.path.join(st, "quota-reserves.json"), "w") as fh:
        json.dump(res, fh, ensure_ascii=False, indent=2)
    return tsv


def snapshot_env(out, tsv):
    st = os.path.join(out, "state")
    return dict(os.environ, HOME=os.path.join(out, "home"), QP_STATE=os.path.join(st, "rate_limits.json"),
                QUOTA_RESERVES=os.path.join(st, "quota-reserves.json"), QP_CODEX_TSV=tsv)


M = {("rich", "rich"): (1, "delegate"), ("rich", "ok"): (2, "cost"), ("rich", "lean"): (3, "direct"), ("rich", "tight"): (4, "no-codex"),
     ("ok", "rich"): (5, "delegate"), ("ok", "ok"): (6, "cost"), ("ok", "lean"): (7, "cost"), ("ok", "tight"): (8, "small-only"),
     ("tight", "rich"): (9, "delegate"), ("tight", "ok"): (10, "delegate"), ("tight", "lean"): (11, "hold"), ("tight", "tight"): (12, "hold")}
WEEK = 7 * 86400
WORK = {"direct": {"n": 12, "ok": 11}, "dispatch": {"n": 5, "ok": 4, "basis": "first-attempt-per-task"}, "active": 2, "review": {"verdicts": 1, "memory": 3}}


def history(snap):
    """合成 7 天、每 30 分鐘一筆的歷史（格式同 bin/publish.sh），最後一筆接到 snapshot 的數值。
    週用量照週期累積：目前週期從 resets_at − 7 天開始、白天用得多（單調遞增）；更早的列屬上一個週期。
    模式／route 用簡化版矩陣規則從合成的盈餘推回；最後 3 小時改用 snapshot 當下的判定（含 override、card）。"""
    end, n, rows = snap["generated_at"], 7 * 48, []
    m = snap["mode"]
    act = lambda t: 1 + 0.8 * math.sin(2 * math.pi * ((t / 3600) % 24 - 6) / 24)   # 一天中的用量節奏（> 0）
    def cum(a, b):                                                                   # ∫ act，從 a 到 b（30 分鐘步長）
        return sum(act(t) for t in range(int(a), int(b), 1800)) * 1800 if b > a else 0.0
    def week(p, prev_total):
        w = (snap.get(p) or {}).get("week") or {}
        if w.get("resets_at") is None: return None
        R, U = w["resets_at"], w["used"]
        while R - WEEK > end: R -= WEEK
        S = R - WEEK
        def at(t):
            if t >= S: return (U * cum(S, t) / cum(S, end) if cum(S, end) else 0.0), 100 * (t - S) / WEEK, R
            return prev_total * cum(S - WEEK, t) / cum(S - WEEK, S), 100 * (t - S + WEEK) / WEEK, S
        return at
    cw, xw = week("claude", 72), week("codex", 64)
    for i in range(n + 1):
        t = round(end - (n - i) * 1800)
        r = {"t": t}
        for p, fn, k in (("claude", cw, "c"), ("codex", xw, "x")):
            if fn is None:
                r.update({k + "5": None, k + "7": None, k + "s": None, k + "r": None}); continue
            used, e, reset = fn(t)
            r.update({k + "5": round(50 + 40 * math.sin(i / (5 if k == "c" else 6)), 1), k + "7": round(used, 1), k + "s": round(e - used, 1), k + "r": round(reset)})
        ct = "ok" if r["cs"] is None else "rich" if r["cs"] >= 15 * min(1, (r["cs"] + r["c7"]) / 50) else "tight" if r["cs"] <= -15 or r["c7"] > 85 else "ok"
        xt = "lean" if r["xs"] is None else "tight" if r["x7"] > 85 or r["xs"] <= -25 else "rich" if r["xs"] >= 15 else "lean" if r["xs"] < 0 else "ok"
        mode, route = M[(ct, xt)]
        ov = "claude5h-low" if (r["c5"] or 0) >= 85 and route in ("cost", "direct") else "-"
        if end - t < 3 * 3600:
            mode, route, ct, xt, ov = int(m.get("mode", 0)), m.get("route"), m.get("claude"), m.get("codex"), m.get("override", "-")
        r.update({"mode": mode, "route": route, "hub": m.get("hub") if end - t < 3 * 3600 else ("sonnet" if ct == "tight" else "opus"),
                  "override": ov, "card": m.get("card", "-") if end - t < 3 * 3600 else "-", "ct": ct, "xt": xt})
        rows.append(r)
    return rows


def build_site(sc, out, now):
    tsv = write_state(sc, out, now)
    shutil.copytree(os.path.join(ROOT, "site"), out, dirs_exist_ok=True, ignore=shutil.ignore_patterns("data"))
    os.makedirs(os.path.join(out, "data"), exist_ok=True)
    snap = json.loads(subprocess.run([os.path.join(ROOT, "bin", "snapshot.sh")], env=snapshot_env(out, tsv),
                                     check=True, capture_output=True, text=True).stdout)
    snap["generated_at"] -= sc.get("snapshot_age", 0)
    with open(os.path.join(out, "data", "snapshot.json"), "w") as fh:
        json.dump(snap, fh, ensure_ascii=False, indent=1)
    with open(os.path.join(out, "data", "history.jsonl"), "w") as fh:
        fh.writelines(json.dumps(r) + "\n" for r in history(snap))
    work = sc.get("work", {})
    if work is not None:
        with open(os.path.join(out, "data", "work.json"), "w") as fh:
            json.dump({"generated_at": snap["generated_at"], **WORK, **work}, fh)


def main(argv):
    if argv[:1] == ["list"]:
        for f in sorted(os.listdir(FIX)):
            if f.endswith(".json"):
                print(f"{f[:-5]:14} {load(f[:-5])['description']}")
        return 0
    if len(argv) != 3 or argv[0] not in ("state", "site"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd, name, out = argv
    sc, now = load(name), time.time()
    os.makedirs(out, exist_ok=True)
    if cmd == "state":
        write_state(sc, out, now)
    else:
        build_site(sc, out, now)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
