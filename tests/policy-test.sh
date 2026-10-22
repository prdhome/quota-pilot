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
eq "--effort 盈餘 36 達 rich → 不降 effort" opus "$(pm --effort)"
st 75 $((NOW+3600)) 43 $((NOW+DAY*147/100)) $NOW
eq "5h 剩 25 不影響主控 → opus" opus "$(pm)"
st 10 $((NOW+3600)) 69 $((NOW+DAY*147/100)) $NOW   # 盈餘 10
eq "盈餘 10 → opus" opus "$(pm)"
eq "detail 第 6 欄：盈餘 10 未達 rich → 0" 0 "$(pm --detail | awk '{print $7}')"
eq "--effort 盈餘 10 未達 rich → opus low" "opus low" "$(pm --effort)"
st 10 $((NOW+3600)) 32 $((NOW+DAY*6)) $NOW   # 週期過 14%、用 32% → 盈餘 −18、週剩 68
eq "盈餘 −18 → sonnet" sonnet "$(pm)"
eq "--effort 吃緊 → sonnet 不附 low" sonnet "$(pm --effort)"
eq "盈餘 −18 已在 opus（遲滯門檻 −25）→ opus" opus "$(pm --current opus)"
st 10 $((NOW+3600)) 87 $((NOW+DAY*147/100)) $NOW   # 盈餘 −8、週剩 13
eq "週剩 13 → sonnet" sonnet "$(pm)"
st 95 $((NOW-60)) 90 $((NOW-DAY)) $((NOW-8*3600))  # 舊讀數、週期已 reset → 用量歸零
eq "閒置後週期已 reset → opus" opus "$(pm)"
st 10 $((NOW+3600)) 87 $((NOW+DAY*147/100)) $((NOW-7*3600))
eq "過期 7h 且未 reset → 預設 opus" opus "$(pm)"
st 10 $((NOW-60)) 95 $((NOW+DAY*3)) $((NOW-8*3600))
eq "只有 5h reset、7d 讀數 8h 前週剩 5 → 過期、預設 opus 且不給 detail 數字" "opus" "$(pm --detail)"
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
rich rich mode=1 hub=opus route=delegate subagent=sonnet ov=-
rich ok mode=2 hub=opus route=cost subagent=sonnet ov=-
rich lean mode=3 hub=opus route=direct subagent=sonnet ov=-
rich tight mode=4 hub=opus route=no-codex subagent=sonnet ov=-
ok rich mode=5 hub=opus route=delegate subagent=sonnet ov=-
ok ok mode=6 hub=opus route=cost subagent=sonnet ov=-
ok lean mode=7 hub=opus route=cost subagent=sonnet ov=-
ok tight mode=8 hub=opus route=small-only subagent=sonnet ov=-
tight rich mode=9 hub=sonnet route=delegate subagent=sonnet ov=-
tight ok mode=10 hub=sonnet route=delegate subagent=sonnet ov=-
tight lean mode=11 hub=sonnet route=hold subagent=sonnet ov=-
tight tight mode=12 hub=sonnet route=hold subagent=sonnet ov=-
M
cst rich; eq "codex 讀不到 → unknown，矩陣當 lean（不推給 Codex）" "mode=3 hub=opus route=direct subagent=sonnet claude=rich codex=unknown override=- card=-" \
  "$("$ROOT/bin/quota-mode.sh" --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv x)"
cst tight; eq "Claude 吃緊＋codex unknown → hold（不盲目派工）" "mode=11 hub=sonnet route=hold subagent=sonnet ov=-" "$(qm x)"
st 80 $((NOW+3600)) 43 $W $NOW
eq "Claude 5h 偏低＋codex unknown → 不轉派工" "mode=3 hub=opus route=direct subagent=sonnet ov=-" "$(qm x)"
st 95 $((NOW+3600)) 43 $W $NOW
eq "Claude 5h 剩 5 → 暫停 Claude、派工（7d 仍 rich）" "mode=2 hub=opus route=delegate subagent=sonnet ov=claude5h" "$(qm "$(xt ok)")"
eq "Claude 5h 剩 5、Codex 吃緊 → hold" "mode=4 hub=opus route=hold subagent=sonnet ov=claude5h" "$(qm "$(xt tight)")"
cst rich
eq "Codex 5h 剩 5 → 不派 Codex" "mode=2 hub=opus route=no-codex subagent=sonnet ov=codex5h" "$(qm "95 70 $((NOW+3600)) $W")"
st 95 $((NOW+3600)) 43 $W $NOW
eq "兩邊 5h 都 < 10 → hold" "mode=2 hub=opus route=hold subagent=sonnet ov=both5h" "$(qm "95 70 $((NOW+3600)) $W")"
eq "Claude 5h 先見底且 1h 內 reset → explain 提示可等" "1" "$("$ROOT/bin/quota-mode.sh" --explain --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$(xt ok)" 2>&1 >/dev/null | grep -c '可等')"
st 80 $((NOW+3600)) 43 $W $NOW
eq "Claude 5h 剩 20 → 7d 仍 rich、暫轉派工" "mode=2 hub=opus route=delegate subagent=sonnet ov=claude5h-low" "$(qm "$(xt ok)")"
eq "Claude 5h 剩 20、Codex 超速 → 不轉給 Codex，維持直做" "mode=3 hub=opus route=direct subagent=sonnet ov=-" "$(qm "$(xt lean)")"
cst rich
eq "Codex 5h 剩 20 → 暫轉直做" "mode=2 hub=opus route=direct subagent=sonnet ov=codex5h-low" "$(qm "80 70 $((NOW+3600)) $W")"
st 10 $((NOW+3600)) 60 $((NOW+DAY/2)) $NOW   # Claude 週過 93%、用 60% → 盈餘 33，12h 內 reset
eq "週末清倉 Claude → 直做＋Opus subagent" "mode=2 hub=opus route=direct subagent=opus ov=weekend-claude" "$(qm "10 50 $((NOW+3600)) $((NOW+DAY*3))")"
cst ok
eq "週末清倉 Codex → 派工" "mode=5 hub=opus route=delegate subagent=sonnet ov=weekend-codex" "$(qm "10 60 $((NOW+3600)) $((NOW+DAY/2))")"

# --- 重置卷 ---
RESV="$T/r.json"
card() { printf '{"cards":[%s]}' "$1" > "$RESV"; }
iso() { python3 -c "import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).isoformat())" "$1"; }
cst rich; card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null}"
eq "Codex 超速＋1 張卷 → 視同 ok" "mode=2 hub=opus route=cost subagent=sonnet ov=- card=-" "$(qm "$(xt lean)")"
eq "Codex 7d 吃緊＋卷 → ok 並提示用卷（週剩 10、自然 reset 1.47 天後）" "mode=2 hub=opus route=cost subagent=sonnet ov=- card=codex:use" "$(qm "$(xt tight)")"
eq "自然 reset 不到 24h → 不提示用卷" "mode=2 hub=opus route=cost subagent=sonnet ov=- card=-" "$(qm "10 90 $((NOW+3600)) $((NOW+DAY/2))")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null},{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*14)))\",\"used_at\":null}"
eq "Codex 超速＋2 張卷 → 視同 rich" "mode=1 hub=opus route=delegate subagent=sonnet ov=- card=-" "$(qm "$(xt lean)")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY)))\",\"used_at\":null}"
eq "卷 24h 內到期、週已用 70% → 提示用掉" "mode=2 hub=opus route=cost subagent=sonnet ov=- card=codex:expiring" "$(qm "$(xt ok)")"
card "{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":\"2026-10-01T00:00:00+08:00\"},{\"provider\":\"codex\",\"expires\":\"$(iso $((NOW-60)))\",\"used_at\":null}"
eq "已用／過期的卷不算" "mode=3 hub=opus route=direct subagent=sonnet ov=- card=-" "$(qm "$(xt lean)")"
cst tight; card "{\"provider\":\"claude\",\"expires\":\"$(iso $((NOW+DAY*7)))\",\"used_at\":null}"
eq "pick-model：Claude 7d 吃緊＋卷 → opus" opus "$(pm)"
eq "Claude 7d 吃緊＋卷 → 視同 ok、主控維持 opus、提示用卷" "mode=6 hub=opus route=cost subagent=sonnet ov=- card=claude:use" "$(qm "$(xt ok)")"
unset RESV

# --- quota-reserve.sh check／use：QP_STATE（Claude）、QP_CODEX_TSV（Codex）注入目前週 reset ---
RESV="$T/rv.json"; mkdir -p "$T/home"
qr() { HOME="$T/home" QUOTA_RESERVES="$RESV" "$ROOT/bin/quota-reserve.sh" "$@"; }
R7=$((NOW+DAY*3))
printf '{"cards":[{"provider":"claude","expires":"2099-01-01T00:00:00+00:00","used_at":"2026-10-10T00:00:00+08:00","reset7_before":%s},{"provider":"codex","expires":"2099-01-01T00:00:00+00:00","used_at":"2026-10-10T00:00:00+08:00","reset7_before":%s}],"credits":[]}' $R7 $R7 > "$RESV"
st 10 $((NOW+3600)) 40 $((R7+300)) $NOW
eq "check：Claude 週 reset 只差 5 分鐘 → 未重開週期" 1 "$(QP_STATE="$T/s.json" qr check | grep -c '^claude.*未變')"
st 10 $((NOW+3600)) 0 $((R7+DAY*4)) $NOW
eq "check：Claude 週 reset 往後跳 → 用卷重開週期" 1 "$(QP_STATE="$T/s.json" qr check | grep -c '^claude.*已改變')"
eq "check：Codex 週 reset 相同 → 未重開週期" 1 "$(QP_CODEX_TSV="0 0 $((NOW+3600)) $R7" qr check | grep -c '^codex.*未變')"
eq "check：Codex 週 reset 往後跳 → 用卷重開週期" 1 "$(QP_CODEX_TSV="0 0 $((NOW+3600)) $((R7+DAY*5))" qr check | grep -c '^codex.*已改變')"
eq "check：讀不到 Codex（QP_CODEX_TSV=-）" 1 "$(QP_CODEX_TSV=- qr check | grep -c '^codex：讀不到目前週 reset')"
eq "check：讀不到 Claude（QP_STATE 指向不存在的檔）" 1 "$(QP_STATE="$T/nope.json" qr check | grep -c '^claude：讀不到目前週 reset')"
printf '{"cards":[{"provider":"claude","expires":"2099-01-01T00:00:00+00:00","used_at":null}],"credits":[]}' > "$RESV"
QP_STATE="$T/s.json" qr use claude >/dev/null
eq "use：記下 QP_STATE 的週 reset 當 reset7_before" "$((R7+DAY*4))" "$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["cards"][0]["reset7_before"]))' "$RESV")"
unset RESV

# --- 門檻同步：網頁 ACTION.cardUseLeft ＝ quota-mode.sh CARD_USE_LEFT 預設值 ---
want=$(sed -nE 's/^CARD_USE_LEFT="\$\{CARD_USE_LEFT:-([0-9.]+)\}"$/\1/p' "$ROOT/bin/quota-mode.sh")
got=$(sed -nE 's/^ *cardUseLeft: *([0-9.]+),.*/\1/p' "$ROOT/site/index.html")
eq "門檻同步：site ACTION.cardUseLeft ＝ quota-mode.sh CARD_USE_LEFT（${want}）" "${want:-缺}" "${got:-缺}"
# 網頁「為什麼是這個模式」的 Codex 門檻 ACTION.thr ＝ quota-mode.sh 預設值
thr_line=$(grep -E '^ *thr: *\{' "$ROOT/site/index.html")
for pair in leftTight:LEFT_TIGHT codexDeficit:CODEX_DEFICIT codexRich:CODEX_RICH; do
  js=${pair%%:*}; sh=${pair##*:}
  want=$(sed -nE "s/^${sh}=\"\\\$\{${sh}:-([0-9.]+)\}\"$/\1/p" "$ROOT/bin/quota-mode.sh")
  got=$(printf '%s' "$thr_line" | sed -nE "s/.*${js}: *([0-9.]+).*/\1/p")
  eq "門檻同步：site ACTION.thr.${js} ＝ quota-mode.sh ${sh}（${want}）" "${want:-缺}" "${got:-缺}"
done

# --- quota-mode.sh --detail：raw／policy 分離、freshness、預估 ---
qd() { "$ROOT/bin/quota-mode.sh" --detail --state "$T/s.json" --now "$NOW" --reserves "${1:-$T/none.json}" --codex-tsv "${2:-$(xt ok)}" | sed -n 's/^detail: //p' | tr ' ' '\n'; }
kv() { grep "^$1=" | cut -d= -f2; }
eq "detail：第一行格式不變" "mode=" "$("$ROOT/bin/quota-mode.sh" --detail --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$(xt ok)" | head -1 | cut -c1-5)"
eq "detail 缺檔 → claude_raw=unknown" unknown "$(QUOTA_RESERVES=x "$ROOT/bin/quota-mode.sh" --detail --state "$T/nope.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$(xt ok)" | sed -n 's/^detail: //p' | tr ' ' '\n' | kv claude_raw)"
eq "detail 缺檔 → fresh=missing" missing "$("$ROOT/bin/quota-mode.sh" --detail --state "$T/nope.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$(xt ok)" | sed -n 's/^detail: //p' | tr ' ' '\n' | kv claude_fresh)"
st 10 $((NOW+3600)) 87 $W $((NOW-7*3600))
eq "detail 過期 7h 未 reset → fresh=stale" stale "$(qd | kv claude_fresh)"
st 95 $((NOW-60)) 50 $W $((NOW-8*3600))
eq "detail 只有 5h reset、讀數 8h 前 → 仍算過期 fresh=stale" stale "$(qd | kv claude_fresh)"
cst tight; printf '{"cards":[{"provider":"claude","expires":"2099-01-01T00:00:00+00:00","used_at":null}]}' > "$T/c1.json"
eq "detail 有卷未用 → raw=tight" tight "$(qd "$T/c1.json" | kv claude_raw)"
eq "detail 有卷未用 → policy=ok" ok "$(qd "$T/c1.json" | kv claude_policy)"
eq "detail 卷數" 1 "$(qd "$T/c1.json" | kv claude_cards)"
eq "detail 週用 95%／過 79% → proj7=120" 120 "$(qd | kv claude_proj7)"
# 用卷只歸零、不重開週期 → 速率改從 used_at 起算（2026-10-22；舊算法週用 20%／過 79% 得 proj7=25，過度樂觀）
st 10 $((NOW+3600)) 20 $((NOW+DAY*147/100)) $NOW
iso() { python3 -c "import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).isoformat())" "$1"; }
cu() { printf '{"cards":[{"provider":"claude","expires":"2099-01-01T00:00:00+00:00","used_at":"%s"}]}' "$(iso "$1")" > "$T/cu.json"; }
cu $((NOW-10*3600))
eq "detail 10h 前用卷、之後用 20% → proj7=91" 91 "$(qd "$T/cu.json" | kv claude_proj7)"
eq "detail 10h 前用卷、之後用 20% → runway_h=40" 40 "$(qd "$T/cu.json" | kv claude_runway_h)"
cu $((NOW-30*60))
eq "detail 用卷不足 1h → proj7 不估" - "$(qd "$T/cu.json" | kv claude_proj7)"
cu $((NOW-DAY*6))
eq "detail 卷用在本週期之前 → 照週期起算 proj7=25" 25 "$(qd "$T/cu.json" | kv claude_proj7)"
st 5 $((NOW+3600)) 69 $W $NOW
eq "detail Claude 5h 剩 95 → left5=95" 95 "$(qd "$T/none.json" "10 95 $((NOW+3600)) $W" | kv claude_left5)"
eq "detail Codex 5h 剩 5 → codex5h 閘門仍在第一行" codex5h "$("$ROOT/bin/quota-mode.sh" --detail --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "95 50 $((NOW+3600)) $W" | head -1 | sed -E 's/.*override=([^ ]*).*/\1/')"

# --- subagent 欄：預設 sonnet，Claude 週末清倉才 opus ---
sa() { "$ROOT/bin/quota-mode.sh" --state "$T/s.json" --now "$NOW" --reserves "$T/none.json" --codex-tsv "$1" | sed -E 's/.*subagent=([^ ]*).*/\1/'; }
cst rich; eq "subagent：hub=opus 平常 → sonnet" sonnet "$(sa "$(xt ok)")"
WE=$((NOW+DAY/2)); st 10 $((NOW+3600)) 50 $WE $NOW
eq "subagent：Claude 週末清倉 → opus" opus "$(sa "10 90 $((NOW+3600)) $((NOW+DAY*5))")"

echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
