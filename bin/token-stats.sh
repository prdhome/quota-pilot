#!/usr/bin/env bash
# token-stats.sh — 近 14 天每天、每個模型的 token 用量（stdout JSON），給儀表板「Token 用量」區塊。不耗 LLM token、不連網。
# 只含：日期、provider、模型名稱、請求數、session 數、四種 token 加總。不含 session id、專案路徑、對話內容（gh-pages 是公開的）。
# 錢在網頁上用 API 單價估算（site/index.html 的 PRICES），這裡只給 token 數。
# 來源：
#   Claude Code：$QP_CLAUDE_PROJECTS（預設 ~/.claude/projects）底下所有 *.jsonl，取 type=assistant 的 message.usage／message.model；
#     同一則回應會分成多行寫入（每個 content block 一行、usage 相同）→ 以 message.id 去重；model 為 <synthetic> 的不算。
#     cache_creation 有 ephemeral_5m／1h 細分就分開記（1h 寫入單價較高），沒有就全算 5m。
#   Codex：$QP_CODEX_SESSIONS（預設 ~/.codex/sessions）底下所有 rollout-*.jsonl，取 event_msg/token_count 的 info.total_token_usage（累計值），
#     與同一檔前一筆相減得增量（重複事件增量為 0）；模型取最近一筆 turn_context／session_meta 的 payload.model。
#     OpenAI 的 input_tokens 含 cached_input_tokens → 未快取輸入＝input − cached。
# 只讀 14 天內修改過的檔案；日期照本機時區。格式不認得的行略過，略過數放在 skipped（讀不到格式時看這裡）。
# 測試：tests/token-stats-test.sh。
python3 -I - "${QP_CLAUDE_PROJECTS:-$HOME/.claude/projects}" "${QP_CODEX_SESSIONS:-$HOME/.codex/sessions}" "${QP_TOKEN_DAYS:-14}" <<'PY'
import glob, json, os, sys, time
from datetime import datetime
claude_dir, codex_dir, days = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = time.time(); cut = now - days * 86400
rows, sessions, skipped = {}, {}, {"claude_lines": 0, "codex_lines": 0, "codex_no_model": 0}
def day(ts):
    t = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    return None if t < cut or t > now + 3600 else time.strftime("%Y-%m-%d", time.localtime(t))
def add(d, p, m, sid, **k):
    r = rows.setdefault((d, p, m), {"d": d, "p": p, "m": m, "n": 0, "in": 0, "out": 0, "cr": 0, "cw5": 0, "cw1h": 0})
    r["n"] += 1
    for f, v in k.items(): r[f] += int(v or 0)
    sessions.setdefault((d, p, m), set()).add(sid)
def recent(pattern):
    for f in glob.glob(pattern, recursive=True):
        try:
            if os.path.getmtime(f) >= cut: yield f
        except OSError: pass

seen = set()
for f in recent(os.path.join(claude_dir, "**", "*.jsonl")):
    for line in open(f, encoding="utf-8", errors="replace"):
        if '"usage"' not in line or '"assistant"' not in line: continue
        try:
            e = json.loads(line); msg = e["message"]; u = msg["usage"]; model = msg["model"]
            if e.get("type") != "assistant" or model == "<synthetic>": continue
            key = msg.get("id") or e.get("requestId") or e.get("uuid") or (f, line)
            if key in seen: continue
            d = day(e["timestamp"])
        except (ValueError, KeyError, TypeError, AttributeError):
            skipped["claude_lines"] += 1; continue
        seen.add(key)
        if not d: continue
        cc = u.get("cache_creation") or {}
        cw1h = cc.get("ephemeral_1h_input_tokens") or 0
        cw5 = cc.get("ephemeral_5m_input_tokens") if cc else None
        if cw5 is None: cw5 = max(0, (u.get("cache_creation_input_tokens") or 0) - cw1h)
        add(d, "claude", model, e.get("sessionId") or f, **{"in": u.get("input_tokens"), "out": u.get("output_tokens"),
            "cr": u.get("cache_read_input_tokens"), "cw5": cw5, "cw1h": cw1h})

for f in recent(os.path.join(codex_dir, "**", "rollout-*.jsonl")):
    model, prev = None, None
    for line in open(f, encoding="utf-8", errors="replace"):
        if '"token_count"' not in line and '"model"' not in line: continue
        try:
            e = json.loads(line); pl = e.get("payload") or {}
            if e.get("type") in ("turn_context", "session_meta") and pl.get("model"): model = pl["model"]; continue
            if e.get("type") != "event_msg" or pl.get("type") != "token_count" or not pl.get("info"): continue
            tot = pl["info"]["total_token_usage"]
            cur = {k: int(tot.get(k) or 0) for k in ("input_tokens", "cached_input_tokens", "output_tokens")}
            d = day(e["timestamp"])
        except (ValueError, KeyError, TypeError, AttributeError):
            skipped["codex_lines"] += 1; continue
        # 累計值倒退（新 session 接在同一檔或計數重設）→ 這筆整個算增量
        inc = cur if prev is None or any(cur[k] < prev[k] for k in cur) else {k: cur[k] - prev[k] for k in cur}
        prev = cur
        if not any(inc.values()) or not d: continue
        if not model: skipped["codex_no_model"] += 1; continue
        add(d, "codex", model, f, **{"in": inc["input_tokens"] - inc["cached_input_tokens"], "cr": inc["cached_input_tokens"], "out": inc["output_tokens"]})

out = []
for k, r in sorted(rows.items()):
    r["s"] = len(sessions[k]); out.append(r)
print(json.dumps({"generated_at": round(now), "days": days, "rows": out, "skipped": skipped}))
PY
