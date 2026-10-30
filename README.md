# quota-pilot

Claude Code ＋ Codex 訂閱額度的動態調度：依兩邊 5h／7d 用量與重置卷，決定**主控模型**、**邊界任務派工或直做**、**subagent 模型**，並發佈成 GitHub Pages 儀表板。

**儀表板**：https://prdhome.github.io/quota-pilot/

## 規則（`bin/quota-mode.sh`）
- **7d 決定模式**（週額度用不完會作廢＝預算）：Claude 3 級（rich／ok／tight）× Codex 4 級（rich／ok／lean／tight）＝ 12 格。
- **5h 只做暫時覆寫**：剩 <10% 該邊暫停；10–30% 新任務暫轉另一邊（對方超速時不轉）。
- **週末清倉**：某邊 7d 在 24h 內重置且盈餘 ≥20 → 放寬那一邊。
- **重置卷**（`bin/quota-reserve.sh`）：有卷時超速／吃緊視同正常，≥2 張視同充裕；週剩 ≤10% 或卷 48h 內到期時提示用卷。
- **主控**（`bin/pick-model.sh`）：一律 Opus，只有 Claude 7d 吃緊且無卷才 Sonnet。

| Claude ＼ Codex | rich | ok | lean | tight |
|---|---|---|---|---|
| rich | 1 派工 | 2 照成本 | 3 直做 | 4 不派 Codex |
| ok | 5 派工 | 6 照成本 | 7 照成本 | 8 只做小任務 |
| tight | 9 派工 | 10 派工 | 11 延後 | 12 延後 |

## 儀表板怎麼看
頁首「今日行動」卡就是今天的結論，文案依 `snapshot.json` 的 mode／route／hub／override／card 產生：
- 第一行大字＝派工方向（route）：派給 Codex／照成本／自己做／不派 Codex／只做小任務／延後。
- 底下最多 2 句：5h 覆寫（哪邊快用完、約幾點恢復）、用卷建議（含最近一張卷的到期日與剩幾天；卷 3 天內到期但還沒輪到該用時溫和提醒），最後一句是主控與 subagent 模型。
- 右上角「x 分鐘前更新」：超過 90 分鐘標「過期」並說明可能原因（Mac 關機或睡眠）；超過 6 小時整張卡降級成「數據過期，建議僅供參考」。
- 讀取失敗分三種顯示：讀不到資料（取不到檔案）、資料格式不對、畫面錯誤（網頁 bug，詳情在瀏覽器 console）。
- 文案、門檻（3 天、90 分鐘、6 小時）都集中在 `site/index.html` 的 `ACTION` 查表物件，調整只改那裡。
- 行動卡中間的藍框：
  - 「下一個轉折」：5h 覆寫結束（附覆寫解除後的派工閘門）、照目前速度週額度見底、週重置、卷到期，取最早的一個，附時間與倒數。
  - 「Harness」：Claude 7d 吃緊（主控已降 Sonnet）或 Claude 5h 見底，且 Codex 充裕／正常時，提示可改用 Codex CLI 當主控。只是畫面提示，不影響 `quota-mode.sh` 判定。
  - 「Claude Code 主控」：照目前主控模型給 `/model opus` 或 `/model sonnet`，點一下就複製。主控是 Opus 時旁邊標 effort：`effort low`＝中間檔（週盈餘未達充裕門檻，啟動時帶 `--effort low`），否則「effort 預設」。effort 由 `snapshot.json` 的 `effort` 欄決定（`bin/pick-model.sh --effort` 產出），網頁不自己算門檻。
- 現況磚（每邊一塊）：兩個圓環＝5h 剩與週剩，顏色是嚴重度不是廠商色。5h 剩 <10% 紅、<30% 黃（`ACTION.thr.block5h／low5h`，須與 `BLOCK_5H／LOW_5H` 一致）；週剩依 7d 等級：吃緊紅、超速黃。
- 行動卡左側色條＝最差狀態：5h 見底、閘門「非急件延後」或數據嚴重過期 → 紅；7d 吃緊／超速、5h 偏低、過期或要用卷 → 黃；其餘綠。
- chip 的 Claude／Codex 等級都標 7d，跟 5h 覆寫分開。
- 「重置卷與點數到期」是時間軸：每張卷／點數一條，黑線是今天，已用或過期的灰掉；沒有登錄任何卷時收成一行。
- 行動卡下方「今天可用」：週剩 ÷ 剩餘天數＝今天大約可用的週額度 %；跟平均每天 14%（100/7）比較：差距在 1 個百分點內標「約平均」（`ACTION.budget.avgTol`），否則標寬或緊。週期 24 小時內重置時，改成「剩下的今天用完」。
- 每邊額度卡底下的燃燒曲線：實線＝本週期的週已用 %；虛線＝照週期進度（對角線）；點線＝照目前平均速度推估到週期結束，下面一句話寫出「約幾點見底」或「結束時約剩幾 %」。推估假設之後照目前速度用，遇到非排程 reset 會不準。
- 每邊額度卡的週盈餘底下一行「上週期」：歷史（保留 14 天）裡最近一次週期結束時剩多少。判準跟 `bin/analyze.py` 一樣：剩 ≥20% 標「浪費」、≤3% 標「見底」，最後讀數離結束超過 6 小時加註；提前重置（用卷或供應商重置）不算浪費。門檻在 `ACTION.lastCycle`。
- 「重置卷與點數到期」底下的「用卷效果」（有已用或過期的卷才顯示）：每張已用卷在 used_at 前後 6 小時內找週已用的最大降幅，寫「用時週剩 Y%，回補 X%」並標時機：週剩 ≤10%（`ACTION.cardUseLeft`）＝時機好、離到期 ≤48 小時＝到期前用掉、其餘＝偏早；降幅不到 10 點標「讀數沒下降」（卷可能沒生效或 used_at 記錯），超出 14 天歷史標「無法評估」。附「建議出現後幾小時才用」（從 history 的 `card` 欄找）或「沒有建議就用了」。過期沒用的卷標「浪費一張」，並列出上次用卷後到到期前有幾筆用卷建議。門檻在 `ACTION.cardEffect`。
- 「工作量（近 7 天）」：讀 `data/work.json`（`bin/work-stats.sh`），四格＝直做通過數、派工 Codex 首次成功數、進行中任務、週回顧待處理（裁決＋memory）。少於 5 件標「樣本少」（`ACTION.work.minN`）；統計超過 90 分鐘沒更新標過期；沒有 `work.json`（orchestrator 沒接上）整塊顯示「還沒接上」，不影響其他區塊。
- 7d 模式矩陣：格子顏色越深＝過去 7 天停在那一格越久（格內小字是占比）；折線＝最近 24 小時走過的模式，終點（藍點）是現在。
- 「規則穩定度（近 7 天）」：模式單日最多切換幾次（附最近 24 小時次數）、3 小時內 A→B→A 來回跳動幾次、主控 Opus↔Sonnet 單日最多切換幾次。算法與門檻跟 `bin/analyze.py` 相同：單日 ≥6 次或來回 ≥3 次標黃，並指出最常來回的兩格與差在哪一邊（例如「M6↔M10（Claude 正常↔吃緊）」），提示跑 `analyze.py` 看門檻附近、考慮加大遲滯；歷史不到 3 天標「僅供參考」。日界照瀏覽器時區（`analyze.py` 照本機時區）；門檻在 `ACTION.stability`。
- 「為什麼是這個模式」：把判斷拆成 Claude 等級、Codex 等級、矩陣、5h 覆寫、主控五步，用實際數字對照門檻說明。Codex 門檻在 `ACTION.thr`，須與 `bin/quota-mode.sh` 一致（`tests/policy-test.sh` 檢查）。
- 「5h 尖峰時段（近 14 天）」：每邊一張熱圖，列＝日期、欄＝0–23 時（瀏覽器時區），格＝那個小時 5h 最高已用的嚴重度：灰＝正常、黃＝偏低（5h 剩 <30%，會觸發覆寫）、紅＝見底（剩 <10%），門檻跟現況圓環同一組（`ACTION.thr.low5h／block5h`）；滑過格子看實際 %。底下一句話找出偏低天數最多的連續 3 小時（可跨午夜），寫「5h 偏低多在 14–17 時：N 天裡有 M 天」，方便把重工作排開。窗口長度在 `ACTION.peaks.win`。歷史只保留 14 天，所以用日期而不是星期幾當列。
- 7 天趨勢圖的垂直虛線＝週期重置（週 reset 時間往後跳；舊資料沒有 `cr／xr` 時看週已用驟降 ≥20 點），盈餘線在那裡斷崖是正常的。重置標籤靠得近時自動錯開成多列，線尾數值接近時上下拉開，窄螢幕會略過擠在一起的日期。
- 7 天趨勢圖底下多一條「建議」時間帶：藍＝派工（Codex 做）、綠＝照成本、橘＝自己做（Claude 做）、灰斜線＝收斂（只做小任務／延後）；▲＝5h 覆寫開始、◆＝用卷建議。滑過圖可看當時的模式與覆寫，表格檢視也多一欄「建議」。

## 資料流
本機 launchd 每 30 分鐘：`bin/publish.sh` → `bin/snapshot.sh`（讀 `~/.claude/state/rate_limits.json`、`codex-quota.sh`、`quota-reserves.json`）→ 推到 `gh-pages` 分支的 `data/`。不耗任何 LLM token；只發佈用量 %、重置時間、模式與卷到期日。

```bash
tests/policy-test.sh          # 規則回歸測試（假資料）
bin/quota-mode.sh --explain   # 看目前判定與依據
bin/publish.sh --init         # 首次建立 gh-pages
bin/install-launchd.sh        # 安裝每 30 分鐘推送
```

## 測試與本機預覽
`tests/fixtures/` 是共用的假情境（充裕、Claude 7d 吃緊、Codex 吃緊、兩邊吃緊延後、5h 覆寫、有重置卷、卷快到期、資料過期、嚴重過期）；時間欄位是相對「現在」的秒數，由 `tests/lib/fixture.py` 換算，不會過期。全部不碰真實額度。

```bash
bash tests/policy-test.sh     # 規則回歸測試（pick-model／quota-mode）
bash tests/snapshot-test.sh   # 每組情境跑 bin/snapshot.sh，檢查 JSON 結構與模式判定
bash tests/analyze-test.sh    # bin/analyze.py 校準報告（tests/fixtures/history/ 假歷史）
bash tests/web-smoke.sh       # 儀表板冒煙測試（Playwright＋Chromium，桌機／手機 375px；行動卡文案、三種錯誤狀態）
SHOTS=/tmp/shots bash tests/web-smoke.sh   # 同上，另存每組情境的截圖
bin/preview.sh                # 列出情境
bin/preview.sh override-5h    # 用該情境的假資料開預覽 http://127.0.0.1:8765/（可加 port）
```

- `web-smoke.sh` 需要 node；第一次跑會自動在 `tests/web/` 安裝 playwright，沒有瀏覽器時先跑 `npx --prefix tests/web playwright install chromium`。
- `snapshot.sh` 測試用 `QP_CODEX_TSV` 注入 Codex 讀數（CI 沒有 codex CLI；設成 `-` = 讀不到）；未設時照舊呼叫 `codex-quota.sh --cached`。
- 新增情境：在 `tests/fixtures/` 加一個 JSON（照現有格式，`expect.mode` 寫預期判定、`expect.action` 寫行動卡必須出現的字；可選 `expect.effort` 寫預期的 `low`／`null`），三個測試與預覽都會自動納入。
- 假網站預設會產生一份 `data/work.json`；情境的 `work` 欄覆寫部分欄位，設 `null`＝不產生（測「還沒接上」）。
- GitHub Actions（`.github/workflows/ci.yml`）在 push 到 main 與每個 PR 跑上面四個測試。

## 校準流程
歷史累積滿 7 天（最好跨過一次週期自然結束）後，用真實數據看門檻要不要調：

```bash
git fetch origin gh-pages                      # analyze.py 不連網，只讀本地 git 物件
python3 bin/analyze.py --gh-pages              # 報告印到 stdout
python3 bin/analyze.py --gh-pages -o /tmp/calib.md
python3 bin/analyze.py path/to/history.jsonl   # 讀任意檔案（例如本機 .pages/data/history.jsonl）
```

報告怎麼看：
- **樣本不足**：資料不到 3 天時開頭會標「樣本不足，僅供參考」，建議只當方向。
- **時間占比／模式切換**：某模式占比異常高，或單日切換很多、出現 3 小時內 A→B→A 的來回跳動，代表常卡在門檻邊緣。
- **週期結束時剩多少**：只算自然結束的週期。剩 ≥20% 標「浪費」，≤3% 標「見底」。最後讀數離結束超過 6 小時會加註，因為實際剩量可能更少。
- **非排程 reset**：
  - 「週期重開」：週期已過% 突然倒退，而且發生在原排程 reset 之前（週 reset 時間往後跳）。OpenAI 主動重置 Codex、或用卷重開週期，都會長這樣。
  - 「只歸零用量」：週期沒變，但週已用驟降 ≥10 點（用卷只歸零用量時）。
  - 兩種都不算「週期結束剩很多」，另列次數與時間點。可以跟 `quota-reserve.sh check` 對照，判斷是不是自己用了卷。
- **門檻附近（±5）**：週盈餘有很長時間落在某條邊界附近，那個門檻就是最敏感的旋鈕。
- **5h／override／card**：5h 衝到 70／90% 的次數與時段、各 override 與用卷建議出現的次數。2026-10-15 前的舊列沒有 override／card 欄位，會略過。
- **建議**：只列門檻名稱、現值、調整方向與理由，不會改任何值。現值是直接從 `bin/pick-model.sh`、`bin/quota-mode.sh` 的預設值宣告行讀出來的。

要改門檻時，下面幾處要一起改：
- `bin/pick-model.sh`（DEFICIT／LEFT_MIN／HYST／SURPLUS_MIN／RAMP）與 `bin/quota-mode.sh`（LEFT_TIGHT、CODEX_*、BLOCK_5H、LOW_5H、WEEKEND、CARD_USE_LEFT 等）。只改預設值，不要改宣告行的格式，因為測試與另一個 repo 都會解析這幾行。
- orchestrator repo 的 `mods/quota-monitor/hooks/lib.ts`：DEFICIT／LEFT_MIN／HYST 要同值（那邊的 `tests/quota-policy-test.sh` 會檢查）。
- `site/index.html` 的 `ACTION.cardUseLeft` 要等於 CARD_USE_LEFT（`tests/policy-test.sh` 會檢查）；`ACTION.soonDays` 是網頁自己的提醒門檻。
- 改完跑全部測試。`tests/policy-test.sh` 的矩陣期望值是照現行門檻寫的，門檻改了，測試資料也要跟著重新設計。
