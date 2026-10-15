#!/usr/bin/env bash
# bin/snapshot.sh 測試：用 tests/fixtures 的每組情境產生假資料，跑 snapshot.sh，檢查 JSON 結構與模式判定。
# 不碰真實額度：HOME 指向暫存空目錄，Codex 讀數用 QP_CODEX_TSV 注入（CI 沒有 codex CLI）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ✅ $1"; }
ng() { fail=$((fail+1)); echo "  ❌ $1"; printf '%s\n' "$2" | sed 's/^/     /'; }
snap() {  # snap <輸出目錄> [QP_CODEX_TSV]：用該目錄的 state/ 跑 snapshot.sh
  HOME="$1/home" QP_STATE="$1/state/rate_limits.json" QUOTA_RESERVES="$1/state/quota-reserves.json" \
    QP_CODEX_TSV="${2:-$(cat "$1/state/codex.tsv")}" "$ROOT/bin/snapshot.sh"
}
check() {  # check <名稱> <snapshot.json> [情境檔]：結構＋情境 expect
  local out
  if out=$(python3 -I "$ROOT/tests/lib/check_snapshot.py" "$2" ${3:+"$3"} 2>&1); then ok "$1"; else ng "$1" "$out"; fi
}

for f in "$ROOT"/tests/fixtures/*.json; do
  n="$(basename "$f" .json)"; d="$T/$n"
  python3 -I "$ROOT/tests/lib/fixture.py" state "$n" "$d" || { ng "${n}：產生假資料" ""; continue; }
  if snap "$d" > "$d/snapshot.json" 2>"$d/err"; then check "$n" "$d/snapshot.json" "$f"; else ng "${n}：snapshot.sh 失敗" "$(cat "$d/err")"; fi
done

# Codex 讀不到（QP_CODEX_TSV=-）→ codex=null、矩陣當 ok
d="$T/rich"; snap "$d" - > "$d/nocodex.json"
check "Codex 讀不到 → codex null、mode=2 codex=unknown" "$d/nocodex.json"
got=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["codex"], s["mode"]["mode"], s["mode"]["codex"])' "$d/nocodex.json")
[[ $got == "None 2 unknown" ]] && ok "Codex 讀不到的判定值" || ng "Codex 讀不到的判定值" "got '$got'"

# Claude state 缺檔 → claude=null、主控預設 opus
d="$T/rich"; mv "$d/state/rate_limits.json" "$d/state/gone.json"; snap "$d" > "$d/noclaude.json"
check "Claude 缺檔 → 結構仍完整" "$d/noclaude.json"
got=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["claude"], s["mode"]["hub"])' "$d/noclaude.json")
[[ $got == "None opus" ]] && ok "Claude 缺檔 → claude null、hub opus" || ng "Claude 缺檔 → claude null、hub opus" "got '$got'"

# 預設路徑（未設 QP_CODEX_TSV）：沒有 codex CLI 的機器上 codex-quota.sh 失敗 → codex=null，不崩潰
if ! command -v codex >/dev/null; then
  d="$T/rich"; HOME="$d/home" QP_STATE="$d/state/gone.json" QUOTA_RESERVES="$d/state/quota-reserves.json" "$ROOT/bin/snapshot.sh" > "$d/default.json"
  check "未設 QP_CODEX_TSV 且無 codex CLI → 照常輸出" "$d/default.json"
else
  echo "  ⏭  本機有 codex CLI，跳過「未設 QP_CODEX_TSV」測試（避免讀真實額度）"
fi

echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
