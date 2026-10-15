#!/usr/bin/env bash
# quota-pilot 規則回歸測試：pick-model.sh／quota-mode.sh 的判斷（假資料，不碰真實額度、不花 token）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { local name="$1" want="$2" got="$3"
  if [[ $got == "$want" ]]; then pass=$((pass+1)); echo "  ✅ $name"; else fail=$((fail+1)); echo "  ❌ $name (want '$want' got '$got')"; fi; }
NOW=1792000000; DAY=86400
st() { printf '{"five_hour_used_pct":%s,"five_hour_resets_at":"%s","seven_day_used_pct":%s,"seven_day_resets_at":"%s","updated_epoch":%s}' "$@" > "$T/s.json"; }
pm() { QUOTA_RESERVES="${RESV:-$T/none.json}" "$ROOT/bin/pick-model.sh" --state "$T/s.json" --now "$NOW" "$@"; }

# --- pick-model.sh：主控一律 Opus，只有 Claude 7d 吃緊（盈餘 ≤ −15 或週剩 < 15）才 sonnet ---
st 10 $((NOW+3600)) 43 $((NOW+DAY*147/100)) $NOW   # 週期過 79%、用 43% → 盈餘 36
eq "盈餘 36 → opus" opus "$(pm)"
eq "detail 第 6 欄：盈餘 36 達 rich 門檻 → 1" 1 "$(pm --detail | awk '{print $7}')"
st 75 $((NOW+3600)) 43 $((NOW+DAY*147/100)) $NOW
eq "5h 剩 25 不影響主控 → opus" opus "$(pm)"
st 10 $((NOW+3600)) 69 $((NOW+DAY*147/100)) $NOW   # 盈餘 10
eq "盈餘 10 → opus" opus "$(pm)"
eq "detail 第 6 欄：盈餘 10 未達 rich → 0" 0 "$(pm --detail | awk '{print $7}')"
st 10 $((NOW+3600)) 32 $((NOW+DAY*6)) $NOW   # 週期過 14%、用 32% → 盈餘 −18、週剩 68
eq "盈餘 −18 → sonnet" sonnet "$(pm)"
eq "盈餘 −18 已在 opus（遲滯門檻 −25）→ opus" opus "$(pm --current opus)"
st 10 $((NOW+3600)) 87 $((NOW+DAY*147/100)) $NOW   # 盈餘 −8、週剩 13
eq "週剩 13 → sonnet" sonnet "$(pm)"
st 95 $((NOW-60)) 90 $((NOW-DAY)) $((NOW-8*3600))  # 舊讀數、週期已 reset → 用量歸零
eq "閒置後週期已 reset → opus" opus "$(pm)"
st 10 $((NOW+3600)) 87 $((NOW+DAY*147/100)) $((NOW-7*3600))
eq "過期 7h 且未 reset → 預設 opus" opus "$(pm)"
eq "缺檔 → 預設 opus" opus "$(QUOTA_RESERVES="$T/none.json" "$ROOT/bin/pick-model.sh" --state "$T/nope.json" --now $NOW)"
echo '{"five_hour_used_pct":1}' > "$T/s.json"
eq "壞檔 → 預設 opus" opus "$(pm)"

# --- quota-mode.sh 矩陣（7d：Claude 3 級 × Codex 4 級）＋5h 覆寫＋週末清倉 ---
W=$((NOW+DAY*147/100))                       # 週期已過 79%
qm() { "$ROOT/bin/quota-mode.sh" --state "$T/s.json" --now "$NOW" --reserves "${RESV:-$T/none.json}" --codex-tsv "$1" | sed -E 's/ claude=.*override=/ ov=/' | if [ -n "${RESV:-}" ]; then cat; else sed 's/ card=-$//'; fi; }
cst() { case $1 in rich) st 10 $((NOW+3600)) 43 $W $NOW ;; ok) st 10 $((NOW+3600)) 69 $W $NOW ;; tight) st 10 $((NOW+3600)) 95 $W $NOW ;; esac; }
xt() { case $1 in rich) echo "10 43 $((NOW+3600)) $W" ;; ok) echo "10 70 $((NOW+3600)) $W" ;; lean) echo "10 85 $((NOW+3600)) $W" ;; tight) echo "10 90 $((NOW+3600)) $W" ;; esac; }
while read -r c x want; do
  cst "$c"; eq "矩陣 claude=$c codex=$x" "$want" "$(qm "$(xt "$x")")"
done <<'M'
rich rich mode=1 hub=opus route=delegate subagent=opus ov=-
rich ok mode=2 hub=opus route=cost subagent=opus ov=-
rich lean mode=3 hub=opus route=direct subagent=opus ov=-
rich tight mode=4 hub=opus route=no-codex subagent=opus ov=-
ok rich mode=5 hub=opus route=delegate subagent=opus ov=-
ok ok mode=6 hub=opus route=cost subagent=opus ov=-
ok lean mode=7 hub=opus route=cost subagent=opus ov=-
ok tight mode=8 hub=opus route=small-only subagent=opus ov=-
tight rich mode=9 hub=sonnet route=delegate subagent=sonnet ov=-
tight ok mode=10 hub=sonnet route=delegate subagent=sonnet ov=-
tight lean mode=11 hub=sonnet route=hold subagent=sonnet ov=-
tight tight mode=12 hub=sonnet route=hold subagent=sonnet ov=-
M
cst rich; eq "codex 讀不到 → unknown，矩陣當 ok" "mode=2 hub=opus route=cost subagent=opus claude=rich codex=unknown override=- card=-" \
  "$("$ROOT/bin/quota-mode.sh" --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv x)"
st 95 $((NOW+3600)) 43 $W $NOW
eq "Claude 5h 剩 5 → 暫停 Claude、派工（7d 仍 rich）" "mode=2 hub=opus route=delegate subagent=opus ov=claude5h" "$(qm "$(xt ok)")"
eq "Claude 5h 剩 5、Codex 吃緊 → hold" "mode=4 hub=opus route=hold subagent=opus ov=claude5h" "$(qm "$(xt tight)")"
cst rich
eq "Codex 5h 剩 5 → 不派 Codex" "mode=2 hub=opus route=no-codex subagent=opus ov=codex5h" "$(qm "95 70 $((NOW+3600)) $W")"
st 95 $((NOW+3600)) 43 $W $NOW
eq "兩邊 5h 都 < 10 → hold" "mode=2 hub=opus route=hold subagent=opus ov=both5h" "$(qm "95 70 $((NOW+3600)) $W")"
eq "Claude 5h 先見底且 1h 內 reset → explain 提示可等" "1" "$("$ROOT/bin/quota-mode.sh" --explain --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$(xt ok)" 2>&1 >/dev/null | grep -c '可等')"
st 80 $((NOW+3600)) 43 $W $NOW
eq "Claude 5h 剩 20 → 7d 仍 rich、暫轉派工" "mode=2 hub=opus route=delegate subagent=opus ov=claude5h-low" "$(qm "$(xt ok)")"
eq "Claude 5h 剩 20、Codex 超速 → 不轉給 Codex，維持直做" "mode=3 hub=opus route=direct subagent=opus ov=-" "$(qm "$(xt lean)")"
cst rich
eq "Codex 5h 剩 20 → 暫轉直做" "mode=2 hub=opus route=direct subagent=opus ov=codex5h-low" "$(qm "80 70 $((NOW+3600)) $W")"
st 10 $((NOW+3600)) 60 $((NOW+DAY/2)) $NOW   # Claude 週過 93%、用 60% → 盈餘 33，12h 內 reset
eq "週末清倉 Claude → 直做＋Opus subagent" "mode=2 hub=opus route=direct subagent=opus ov=weekend-claude" "$(qm "10 50 $((NOW+3600)) $((NOW+DAY*3))")"
cst ok
eq "週末清倉 Codex → 派工" "mode=5 hub=opus route=delegate subagent=opus ov=weekend-codex" "$(qm "10 60 $((NOW+3600)) $((NOW+DAY/2))")"

# --- 重置卷 ---
RESV="$T/r.json"
card() { printf '{"cards":[%s]}' "$1" > "$RESV"; }
iso() { python3 -c "import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).isoformat())" "$1"; }
cst rich; card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null}"
eq "Codex 超速＋1 張卷 → 視同 ok" "mode=2 hub=opus route=cost subagent=opus ov=- card=-" "$(qm "$(xt lean)")"
eq "Codex 7d 吃緊＋卷 → ok 並提示用卷（週剩 10、自然 reset 1.47 天後）" "mode=2 hub=opus route=cost subagent=opus ov=- card=codex:use" "$(qm "$(xt tight)")"
eq "自然 reset 不到 24h → 不提示用卷" "mode=2 hub=opus route=cost subagent=opus ov=- card=-" "$(qm "10 90 $((NOW+3600)) $((NOW+DAY/2))")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null},{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*14)))\",\"used_at\":null}"
eq "Codex 超速＋2 張卷 → 視同 rich" "mode=1 hub=opus route=delegate subagent=opus ov=- card=-" "$(qm "$(xt lean)")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY)))\",\"used_at\":null}"
eq "卷 24h 內到期、週已用 70% → 提示用掉" "mode=2 hub=opus route=cost subagent=opus ov=- card=codex:expiring" "$(qm "$(xt ok)")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":\"2026-10-01T00:00:00+08:00\"},{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW-60)))\",\"used_at\":null}"
eq "已用／過期的卷不算" "mode=3 hub=opus route=direct subagent=opus ov=- card=-" "$(qm "$(xt lean)")"
cst tight; card "{\"provider\":\"claude\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null}"
eq "pick-model：Claude 7d 吃緊＋卷 → opus" opus "$(pm)"
eq "Claude 7d 吃緊＋卷 → 視同 ok、主控維持 opus、提示用卷" "mode=6 hub=opus route=cost subagent=opus ov=- card=claude:use" "$(qm "$(xt ok)")"
unset RESV

echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
