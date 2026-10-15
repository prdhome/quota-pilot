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
- 「重置卷與點數到期」是時間軸：每張卷／點數一條，黑線是今天，已用或過期的灰掉。

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
bash tests/web-smoke.sh       # 儀表板冒煙測試（Playwright＋Chromium，桌機／手機 375px；行動卡文案、三種錯誤狀態）
SHOTS=/tmp/shots bash tests/web-smoke.sh   # 同上，另存每組情境的截圖
bin/preview.sh                # 列出情境
bin/preview.sh override-5h    # 用該情境的假資料開預覽 http://127.0.0.1:8765/（可加 port）
```

- `web-smoke.sh` 需要 node；第一次跑會自動在 `tests/web/` 安裝 playwright，沒有瀏覽器時先跑 `npx --prefix tests/web playwright install chromium`。
- `snapshot.sh` 測試用 `QP_CODEX_TSV` 注入 Codex 讀數（CI 沒有 codex CLI；設成 `-` = 讀不到）；未設時照舊呼叫 `codex-quota.sh --cached`。
- 新增情境：在 `tests/fixtures/` 加一個 JSON（照現有格式，`expect.mode` 寫預期判定、`expect.action` 寫行動卡必須出現的字），三個測試與預覽都會自動納入。
- GitHub Actions（`.github/workflows/ci.yml`）在 push 到 main 與每個 PR 跑上面三個測試。
