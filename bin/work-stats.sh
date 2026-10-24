#!/usr/bin/env bash
# work-stats.sh — 近 7 天 orchestrator 直做／派工次數與通過數（stdout JSON），給儀表板健康的 Agent OS 區塊。不耗 LLM token。
# 只含次數：不含 task id、slug、路徑（gh-pages 是公開的）。測試用任務（mtest／smoke／verify-）不算。
# review：週回顧待裁決／待轉換 memory 的件數（不含內容）。
# 來源：$QP_ORCH（預設 ~/Documents/orchestrator）的 tasks/direct-log.tsv（outcome 第 6 欄）、tasks/metrics.tsv（第 8 欄）、tasks/active/。
ORCH="${QP_ORCH:-$HOME/Documents/orchestrator}"
[ -d "$ORCH/tasks" ] || { echo "work-stats: 找不到 $ORCH/tasks" >&2; exit 1; }
python3 -I - "$ORCH/tasks" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone
t = sys.argv[1]; now = time.time(); cut = now - 7 * 86400
def rows(name, ok_col):
    p = os.path.join(t, name); n = ok = 0
    for line in (open(p, encoding="utf-8").read().splitlines()[1:] if os.path.exists(p) else []):
        f = line.split("\t")
        try: ts = datetime.strptime(f[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        except (ValueError, IndexError): continue
        if ts < cut or len(f) <= ok_col or f[1].startswith(("mtest", "smoke", "verify-")): continue
        n += 1; ok += f[ok_col] == "pass"
    return {"n": n, "ok": ok}
ad = os.path.join(t, "active")
# 週回顧待裁決數（只放次數）：orchestrator bin/weekly-review.sh 每項一行「☐ 裁決…」／「☐ memory…」
import subprocess
rv = None
try:
    r = subprocess.run([os.path.join(os.path.dirname(t), "bin", "weekly-review.sh")], capture_output=True, text=True, timeout=30)
    out = r.stdout
    if r.returncode != 0 or not out.startswith("# 週回顧"):  # 失敗就留 null，頁面顯示「還沒接上」，不冒充 0
        raise RuntimeError("weekly-review failed")
    rv = {"verdicts": sum(l.startswith("☐") and " 裁決 " in l for l in out.splitlines()), "memory": sum(l.startswith("☐") and " memory " in l for l in out.splitlines())}  # 含覆核／格式錯誤／清理
except Exception:
    pass
print(json.dumps({"generated_at": round(now), "direct": rows("direct-log.tsv", 5), "dispatch": rows("metrics.tsv", 7),
                  "active": len([x for x in os.listdir(ad) if not x.startswith(".")]) if os.path.isdir(ad) else 0,
                  "review": rv}))
PY
