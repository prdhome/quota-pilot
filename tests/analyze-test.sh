#!/usr/bin/env bash
# bin/analyze.py 測試：用 tests/fixtures/history/ 的假歷史檢查校準報告的關鍵數字與建議段落。時間一律以 UTC 顯示。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export TZ=UTC
H="$ROOT/tests/fixtures/history"; A="$ROOT/bin/analyze.py"
pass=0; fail=0
eq() { local name="$1" want="$2" got="$3"
  if [[ $got == "$want" ]]; then pass=$((pass+1)); echo "  ✅ $name"; else fail=$((fail+1)); echo "  ❌ $name (want '$want' got '$got')"; fi; }
has() { local name="$1" needle="$2" hay="$3"   # 報告裡要有這段字
  if [[ $hay == *"$needle"* ]]; then pass=$((pass+1)); echo "  ✅ $name"; else fail=$((fail+1)); echo "  ❌ $name（報告裡沒有 '$needle'）"; fi; }
hasnt() { local name="$1" needle="$2" hay="$3"
  if [[ $hay != *"$needle"* ]]; then pass=$((pass+1)); echo "  ✅ $name"; else fail=$((fail+1)); echo "  ❌ $name（報告不該有 '$needle'）"; fi; }
j() { python3 -I "$A" --json "$H/$1.jsonl" | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($2)"; }   # j <情境> <python 運算式，s=統計>
md() { python3 -I "$A" "$H/$1.jsonl"; }
sugg='" ".join(x["threshold"] + x["direction"] for x in s["suggestions"])'

# --- 假歷史與產生器同步 ---
python3 -I "$H/gen.py" "$T/gen" && eq "fixtures/history 與 gen.py 輸出一致" "" "$(diff -r -x gen.py -x __pycache__ "$T/gen" "$H" 2>&1 | head -3)"

# --- 門檻從 bin/ 預設值解析 ---
eq "解析到 12 個校準門檻＋CLAUDE_DEFICIT" "15 15 10 15 50 15 15 25 10 30 20 10 15" \
  "$(j short '" ".join(f"{s["thresholds"][k]:g}" for k in ("DEFICIT","LEFT_MIN","HYST","SURPLUS_MIN","RAMP","LEFT_TIGHT","CODEX_RICH","CODEX_DEFICIT","BLOCK_5H","LOW_5H","WEEKEND","CARD_USE_LEFT","CLAUDE_DEFICIT"))')"

echo "穩定充裕一週"
eq "7 天、337 列、不標樣本不足" "7.0 337 False" "$(j stable-rich 's["days"], s["rows"], s["insufficient"]')"
eq "模式占比 M1 62.6%、M2 37.4%" "{'1': 62.6, '2': 37.4}" "$(j stable-rich 's["share"]["mode"]')"
eq "沒有來回跳動，單日切換 ≤1" "1 0" "$(j stable-rich 's["switches"]["max_per_day"], s["switches"]["flaps"]')"
eq "兩邊各自然結束一次、剩 40%" "[40.2] [40.2]" "$(j stable-rich '[e["left"] for e in s["cycles"]["claude"]["ends"]], [e["left"] for e in s["cycles"]["codex"]["ends"]]')"
eq "Claude 整週 rich 仍剩 → 只建議 WEEKEND↓（不建議 SURPLUS_MIN）；Codex → CODEX_RICH↓" "WEEKEND↓ CODEX_RICH↓" "$(j stable-rich "$sugg")"
r="$(md stable-rich)"; hasnt "報告不標樣本不足" "樣本不足" "$r"; has "週期結束表標浪費" "| Claude | 10/07 12:00 | 40% | 浪費 |" "$r"
has "建議表列 WEEKEND 現值與理由" "| WEEKEND | 20 | ↓ | Claude 週期結束時平均剩 40%，但 100% 時間已判 rich" "$r"

echo "Claude 超速後見底"
eq "Claude 週期結束剩 0（見底）" "[0.0]" "$(j claude-overrun '[e["left"] for e in s["cycles"]["claude"]["ends"]]')"
eq "主控 Sonnet 占 40.1%（M10）" "40.1" "$(j claude-overrun 's["share"]["hub"]["sonnet"]')"
eq "Claude 5h ≥70% 17 次、≥90% 16 次" "17 16" "$(j claude-overrun 's["five_hour"]["claude"]["70"]["episodes"], s["five_hour"]["claude"]["90"]["episodes"]')"
eq "5h ≥90% 時段集中在白天（UTC 01–13 時才衝高）" "{'00-06': 7, '06-12': 8, '12-18': 1}" "$(j claude-overrun 's["five_hour"]["claude"]["90"]["slots"]')"
eq "建議 DEFICIT↓ LEFT_MIN↑ LOW_5H↑ BLOCK_5H↑" "DEFICIT↓ LEFT_MIN↑ LOW_5H↑ BLOCK_5H↑" "$(j claude-overrun "$sugg")"
r="$(md claude-overrun)"; has "週期結束表標見底" "| 0% | 見底 |" "$r"
has "目前週期超速 → 提示會提前見底（不印負數）" "Claude 目前週期：已過 14%、已用 18%，照目前速度會在週期結束前見底" "$r"; hasnt "沒有負的剩量" "約剩 -" "$r"

echo "門檻附近反覆切換"
eq "單日最多切換 16 次、來回跳動 45 次、主控單日切 16 次" "16 45 16" "$(j flapping 's["switches"]["max_per_day"], s["switches"]["flaps"], s["switches"]["hub_max_per_day"]')"
eq "Claude 盈餘 100% 時間在吃緊門檻 ±5 內" "100.0" "$(j flapping 's["boundary"]["claude_tight"]')"
eq "建議 HYST↑" "HYST↑" "$(j flapping "$sugg")"
has "理由指出停留最久的邊界" "停留最久的邊界是 claude_tight（100.0% 時間在 ±5 內）" "$(md flapping)"

echo "週期 reset 前剩很多"
eq "Claude 剩 40%、Codex 剩 42%" "[40.0] [42.0]" "$(j waste '[e["left"] for e in s["cycles"]["claude"]["ends"]], [e["left"] for e in s["cycles"]["codex"]["ends"]]')"
eq "rich 占比不高 → 建議 SURPLUS_MIN↓ RAMP↓ WEEKEND↓ CODEX_RICH↓" "SURPLUS_MIN↓ RAMP↓ WEEKEND↓ CODEX_RICH↓" "$(j waste "$sugg")"

echo "Codex 非排程 reset"
eq "偵測到 2 次：週期重開 54.7%→0、只歸零用量 46%→0" "[('週期重開', 54.7, 0.0), ('只歸零用量', 46.0, 0.0)]" \
  "$(j codex-unscheduled '[(u["kind"], u["used_before"], u["used_after"]) for u in s["cycles"]["codex"]["unscheduled"]]')"
eq "非排程 reset 不算週期結束（Codex 無自然結束）；Claude 自然結束 1 次" "0 1 0" \
  "$(j codex-unscheduled 'len(s["cycles"]["codex"]["ends"]), len(s["cycles"]["claude"]["ends"]), len(s["cycles"]["claude"]["unscheduled"])')"
eq "週期重開的原排程 reset ≈ 10/10 00:00（盈餘取到 0.1，誤差 < 1 分鐘）" "True" "$(j codex-unscheduled 'abs(s["cycles"]["codex"]["unscheduled"][0]["due_t"] - 1791590400) < 60')"
r="$(md codex-unscheduled)"
has "非排程 reset 表" "| Codex | 10/06 12:00 | 週期重開 | 55% → 0% | 50% | 10/10 00:00 |" "$r"
has "非排程 reset 次數" "Claude 0 次、Codex 2 次。" "$r"
has "提醒別只憑少數週期調 Codex" "Codex 有 2 次非排程 reset" "$r"
has "沒有門檻建議時明說" "目前數據沒有明顯需要調整的門檻。" "$r"

echo "新舊欄位混合＋壞資料"
eq "略過 3 列（不是 JSON／缺欄／型別錯誤各 1），不中止" "3 {'不是 JSON': 1, '缺必要欄位': 1, '欄位型別錯誤': 1} 193" "$(j mixed-columns 's["skipped"], s["skip_reasons"], s["rows"]')"
eq "override 只算新格式 97 列、舊列 96 略過" "97 96" "$(j mixed-columns 's["override"]["rows_with_field"], s["override"]["rows_without_field"]')"
eq "override：claude5h 10 段 5h、claude5h-low 10 段 10h" "{'claude5h': {'episodes': 10, 'hours': 5.0}, 'claude5h-low': {'episodes': 10, 'hours': 10.0}}" "$(j mixed-columns 's["override"]["values"]')"
eq "card：codex:expiring 1 段 3h、claude:use 1 段 2h" "[('codex:expiring', 1791374400, 3.0), ('claude:use', 1791460800, 2.0)]" \
  "$(j mixed-columns '[(e["value"], e["start"], e["hours"]) for e in s["card"]["episodes"]]')"
r="$(md mixed-columns)"
has "報告列出略過原因" "略過 3 列：不是 JSON 1、缺必要欄位 1、欄位型別錯誤 1" "$r"
has "card 出現時間點" "出現時間點：10/07 12:00 codex:expiring、10/08 12:00 claude:use" "$r"
eq "舊格式全檔：override 段說明沒有欄位" 1 "$(md stable-rich | grep -c '所有列都沒有 override 欄位')"

echo "樣本不足"
r="$(md short)"
has "開頭標樣本不足" "> ⚠️ **樣本不足，僅供參考**：資料只涵蓋 1.0 天" "$r"
eq "樣本不足警示在報告最前面（第 3 行）" "3" "$(md short | grep -n '樣本不足，僅供參考' | head -1 | cut -d: -f1)"
has "建議段落也提示樣本不足" "> 樣本不足：以下只是方向提示" "$r"

echo "輸入邊界"
: > "$T/empty.jsonl"
eq "空檔：0 列、樣本不足、不崩潰" "0 True" "$(python3 -I "$A" --json "$T/empty.jsonl" | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(s["rows"], s["insufficient"])')"
python3 -I "$A" "$H/short.jsonl" -o "$T/out.md"; eq "-o 寫到指定檔、內容同 stdout" "" "$(diff <(md short) "$T/out.md")"
eq "--ref 指向不存在的分支 → exit 1 並提示 fetch" "1 1" "$(python3 -I "$A" --gh-pages --ref no-such-ref 2>"$T/err" >/dev/null; echo "$? $(grep -c 'git fetch origin gh-pages' "$T/err")")"
eq "路徑與 --gh-pages 都給 → 參數錯誤" "2" "$(python3 -I "$A" --gh-pages "$H/short.jsonl" >/dev/null 2>&1; echo $?)"
if git -C "$ROOT" rev-parse -q --verify origin/gh-pages >/dev/null; then
  eq "--gh-pages 讀本地 git 物件產生報告" 1 "$(python3 -I "$A" --gh-pages | grep -c '^# quota-pilot 規則校準報告')"
else
  echo "  ⏭  沒有 origin/gh-pages（CI 淺層 checkout），跳過 --gh-pages 實讀"
fi

echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
