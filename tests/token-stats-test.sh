#!/usr/bin/env bash
# bin/token-stats.sh 測試：假的 ~/.claude/projects 與 ~/.codex/sessions，檢查去重、cache 5m／1h 分開、Codex 累計值相減、14 天視窗、輸出不含路徑與 session id。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TZ=UTC
pass=0; fail=0
eq() { if [[ $3 == "$2" ]]; then pass=$((pass+1)); echo "  ✅ $1"; else fail=$((fail+1)); echo "  ❌ $1 (want '$2' got '$3')"; fi; }
python3 -I - "$T" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone
T = sys.argv[1]; now = time.time()
iso = lambda t: datetime.fromtimestamp(t, timezone.utc).isoformat().replace("+00:00", "Z")
c = os.path.join(T, "claude", "-Users-me-secret-project"); os.makedirs(os.path.join(c, "sub"))
u = lambda i, o, cr, cc, br=None: {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr, "cache_creation_input_tokens": cc, **({"cache_creation": br} if br else {})}
a = lambda mid, model, usage, t, sid="sess-secret-1": json.dumps({"type": "assistant", "timestamp": iso(t), "sessionId": sid, "message": {"id": mid, "model": model, "usage": usage}})
lines = [
  a("m1", "claude-opus-5-5", u(10, 100, 1000, 300, {"ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200}), now - 3600),
  a("m1", "claude-opus-5-5", u(10, 100, 1000, 300, {"ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200}), now - 3600),  # 同一則回應的第二個 content block
  a("m2", "claude-opus-5-5", u(5, 50, 0, 40), now - 1800),                 # 沒有細分 → 全算 5m
  a("m3", "<synthetic>", u(1, 1, 0, 0), now - 1800),
  a("m4", "claude-sonnet-5-5", u(7, 70, 0, 0), now - 1800, "sess-secret-2"),
  a("m5", "claude-opus-5-5", u(1, 1, 0, 0), now - 20 * 86400),           # 視窗外
  '{"type": "user", "message": {"content": "hello secret"}}',
  '{not json "usage" "assistant"',
]
open(os.path.join(c, "s1.jsonl"), "w").write("\n".join(lines) + "\n")
open(os.path.join(c, "sub", "agent.jsonl"), "w").write(a("m6", "claude-opus-5-5", u(1, 2, 3, 0), now - 600) + "\n")   # subagent 檔也要算
old = os.path.join(c, "old.jsonl"); open(old, "w").write(a("m7", "claude-opus-5-5", u(9, 9, 9, 9), now - 3600) + "\n")
os.utime(old, (now - 30 * 86400, now - 30 * 86400))                       # 檔案太舊 → 不讀
x = os.path.join(T, "codex", "2026", "10", "30"); os.makedirs(x)
tc = lambda t, i, ci, o: json.dumps({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": i, "cached_input_tokens": ci, "output_tokens": o, "reasoning_output_tokens": 0, "total_tokens": i + o}}}})
open(os.path.join(x, "rollout-secret.jsonl"), "w").write("\n".join([
  json.dumps({"timestamp": iso(now - 3000), "type": "session_meta", "payload": {"cwd": "/Users/me/secret"}}),
  tc(now - 2990, 50, 0, 5),                                                  # 還不知道模型 → 略過並計數
  json.dumps({"timestamp": iso(now - 2900), "type": "turn_context", "payload": {"model": "gpt-6.1-sol", "cwd": "/Users/me/secret"}}),
  tc(now - 2800, 1000, 600, 100),
  tc(now - 2800, 1000, 600, 100),                                            # 重複事件 → 增量 0
  json.dumps({"timestamp": iso(now - 2700), "type": "event_msg", "payload": {"type": "token_count", "info": None}}),
  tc(now - 2600, 1500, 900, 160),
]) + "\n")
PY
out="$(QP_CLAUDE_PROJECTS="$T/claude" QP_CODEX_SESSIONS="$T/codex" "$ROOT/bin/token-stats.sh")" || { echo "  ❌ token-stats.sh 失敗"; exit 1; }
j() { python3 -I -c "import json,sys; s=json.loads(sys.argv[1]); R={(r['p'],r['m']):r for r in s['rows']}; print($1)" "$out"; }
eq "Claude Opus：m1 去重、m2 無細分算 5m、subagent 檔有算（3 則、in/out/cr/cw5/cw1h）" "3 16 152 1003 140 200" "$(j "' '.join(str(R[('claude','claude-opus-5-5')][k]) for k in ('n','in','out','cr','cw5','cw1h'))")"
eq "Sonnet 另列、<synthetic> 不算、視窗外與舊檔不算" "['claude-opus-5-5', 'claude-sonnet-5-5', 'gpt-6.1-sol']" "$(j "sorted(m for _, m in R)")"
eq "session 數（不輸出 id）：subagent 檔跟主對話同一個 sessionId → Opus 1、Sonnet 1" "1 1" "$(j "R[('claude','claude-opus-5-5')]['s'], R[('claude','claude-sonnet-5-5')]['s']")"
eq "Codex：累計相減、重複事件不重算、未快取＝input−cached（2 次、in 350+200、cr 600+300、out 95+60）" "2 550 900 155" "$(j "' '.join(str(R[('codex','gpt-6.1-sol')][k]) for k in ('n','in','cr','out'))")"
eq "略過計數：Claude 壞行 1、Codex 無模型 1" "1 1" "$(j "s['skipped']['claude_lines'], s['skipped']['codex_no_model']")"
[[ $out != *secret* && $out != *Users* && $out != *sess-* ]] && { pass=$((pass+1)); echo "  ✅ 不含路徑、session id、對話內容"; } || { fail=$((fail+1)); echo "  ❌ 輸出含敏感字串：$out"; }
out2="$(QP_CLAUDE_PROJECTS="$T/none" QP_CODEX_SESSIONS="$T/none" "$ROOT/bin/token-stats.sh")"
eq "兩邊目錄都不存在 → 照常輸出空 rows" "[]" "$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["rows"])' "$out2")"
echo "pass=$pass fail=$fail"; exit $((fail > 0))
