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

## 資料流
本機 launchd 每 30 分鐘：`bin/publish.sh` → `bin/snapshot.sh`（讀 `~/.claude/state/rate_limits.json`、`codex-quota.sh`、`quota-reserves.json`）→ 推到 `gh-pages` 分支的 `data/`。不耗任何 LLM token；只發佈用量 %、重置時間、模式與卷到期日。

```bash
tests/policy-test.sh          # 規則回歸測試（假資料）
bin/quota-mode.sh --explain   # 看目前判定與依據
bin/publish.sh --init         # 首次建立 gh-pages
bin/install-launchd.sh        # 安裝每 30 分鐘推送
```
