#!/usr/bin/env bash
# codex-quota.sh — 查 Codex 剩餘額度（不經 LLM、不耗 token）。
# 輸出一行 TSV：5h_used_pct <TAB> weekly_used_pct <TAB> 5h_reset_epoch <TAB> weekly_reset_epoch
# `--human`：改印「剩餘 %」可讀格式。失敗 exit 1。
# 每次成功查詢寫入 ~/.claude/state/codex_limits.json；`--cached` 先讀該檔，300s 內有效就不啟動 app-server（quota-monitor mod 每 5 分鐘刷新）。
# 原理：codex app-server --stdio 的 JSON-RPC `account/rateLimits/read`（2026-10-14 實測，codex-cli 0.162.1）。
exec python3 -I - "$@" <<'PY'
import subprocess, json, select, time, os, sys
cache = os.path.expanduser("~/.claude/state/codex_limits.json")
def emit(a5, a7, r5, r7):
    if "--human" in sys.argv: print(f"剩餘：5 小時 {100-a5}%、每週 {100-a7}%")
    else: print(a5, a7, r5, r7, sep="\t")
    sys.exit(0)
if "--cached" in sys.argv:
    try:
        c = json.load(open(cache))
        if time.time() - c["updated_epoch"] <= 300: emit(*c["row"])
    except (OSError, ValueError, KeyError, TypeError): pass
p = subprocess.Popen(["codex", "app-server", "--stdio"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
def send(x):
    p.stdin.write((json.dumps(x) + "\n").encode()); p.stdin.flush()
send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "quota_check", "version": "1.0"}}})
end = time.time() + 25; buf = b""
while time.time() < end:
    if not select.select([p.stdout], [], [], 1)[0]: continue
    chunk = os.read(p.stdout.fileno(), 65536)
    if not chunk: break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try: d = json.loads(line)
        except ValueError: continue
        if d.get("id") == 1:
            send({"method": "initialized"}); send({"id": 2, "method": "account/rateLimits/read"})
        elif d.get("id") == 2:
            p.terminate()
            r = d["result"]["rateLimits"]; a, b = r["primary"], r["secondary"]
            row = [a["usedPercent"], b["usedPercent"], a["resetsAt"], b["resetsAt"]]
            try:
                os.makedirs(os.path.dirname(cache), exist_ok=True)
                with open(cache + ".tmp", "w") as fh:
                    json.dump({"row": row, "weekly_window_mins": b.get("windowDurationMins"), "updated_epoch": int(time.time())}, fh)
                os.replace(cache + ".tmp", cache)
            except OSError: pass
            emit(*row)
p.terminate(); sys.exit(1)
PY
