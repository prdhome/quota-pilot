#!/usr/bin/env python3
"""把 tests/fixtures/<情境>.json 換算成以「現在」為基準的假資料（規則測試、snapshot 測試、網頁冒煙測試與 bin/preview.sh 共用）。

情境檔的時間欄位都是相對秒數（*_in = 現在之後、*_ago = 現在之前），所以假資料不會隨日期過期。

  fixture.py state <情境> <輸出目錄>   寫 state/rate_limits.json、state/quota-reserves.json、state/codex.tsv（Codex 讀不到時為 "-"）
  fixture.py site  <情境> <輸出目錄>   state ＋ 複製 site/ ＋ 用 bin/snapshot.sh 產生 data/snapshot.json ＋ 合成 7 天 data/history.jsonl
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


def history(snap):
    """合成 7 天、每 30 分鐘一筆的歷史，最後一筆接到 snapshot 的數值。"""
    end, n, rows = snap["generated_at"], 7 * 48, []
    def g(*path):
        o = snap
        for k in path:
            o = (o or {}).get(k)
        return o
    cs, xs = g("claude", "surplus"), g("codex", "surplus")
    for i in range(n + 1):
        f = i / n
        wave = lambda ph: 8 * math.sin(2 * math.pi * (f * 7 + ph)) * (1 - f)
        rows.append({"t": round(end - (n - i) * 1800), "mode": int(snap["mode"].get("mode", 0)), "route": snap["mode"].get("route"),
                     "hub": snap["mode"].get("hub"),
                     "c5": None if cs is None else round(50 + 40 * math.sin(i / 5), 1), "c7": None if cs is None else round(f * g("claude", "week", "used"), 1),
                     "cs": None if cs is None else round(cs * f + wave(0), 1),
                     "x5": None if xs is None else round(50 + 40 * math.cos(i / 6), 1), "x7": None if xs is None else round(f * g("codex", "week", "used"), 1),
                     "xs": None if xs is None else round(xs * f + wave(0.3), 1)})
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
