#!/usr/bin/env bash
# codex-quota.sh — 查 Codex 剩餘額度（不經 LLM、不耗 token）。
# 輸出一行 TSV：5h_used_pct <TAB> weekly_used_pct <TAB> 5h_reset_epoch <TAB> weekly_reset_epoch
# `--human`：改印「剩餘 %」可讀格式。失敗 exit 1。
# 每次成功查詢寫入 ~/.claude/state/codex_limits.json；`--cached` 先讀該檔，300s 內有效就不啟動 app-server（quota-monitor mod 每 5 分鐘刷新）。
# 原理：codex app-server --stdio 的 JSON-RPC `account/rateLimits/read`（2026-10-14 實測，codex-cli 0.162.1）。
exec python3 -I - "$@" <<'PY'
import subprocess, json, select, signal, time, os, sys
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
def on_term(sig, _frame):
    # 預設 SIGTERM 直接結束、不跑 finally，會留下 app-server；改成 SystemExit 讓 finally 收尾（adversarial review 10-29）
    sys.exit(128 + sig)
for _s in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(_s, on_term)
def reap(p):
    # 不論成功、解析錯誤或中斷都收掉 app-server：terminate → 限時 wait → kill（2026-10-29 bin/ 審查）
    for _s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(_s, signal.SIG_IGN)  # 收尾中不再被重複訊號打斷
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
def save_cache(row, b):
    import tempfile
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cache), prefix=".codex_limits.")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump({"row": row, "weekly_window_mins": b.get("windowDurationMins"), "updated_epoch": int(time.time())}, fh)
            os.replace(tmp, cache)
        except BaseException:
            os.unlink(tmp); raise
    except OSError: pass
# 建子程序期間先擋住 TERM/HUP：Popen 回來到進 try 之間收到訊號會跳過 finally、留下 app-server；進 try 才解除（待處理的訊號此時才送達）
TERMS = {signal.SIGTERM, signal.SIGHUP}
signal.pthread_sigmask(signal.SIG_BLOCK, TERMS)
p = subprocess.Popen(["codex", "app-server", "--stdio"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMS))  # 子程序不繼承遮罩
row = None
try:
    signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMS)
    def send(x):
        p.stdin.write((json.dumps(x) + "\n").encode()); p.stdin.flush()
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "quota_check", "version": "1.0"}}})
    end = time.time() + 25; buf = b""
    while row is None and time.time() < end:
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
                r = d["result"]["rateLimits"]; a, b = r["primary"], r["secondary"]
                row = [a["usedPercent"], b["usedPercent"], a["resetsAt"], b["resetsAt"]]
                save_cache(row, b)
                break
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    row = None
finally:
    reap(p)
if row is None: sys.exit(1)
emit(*row)
PY
