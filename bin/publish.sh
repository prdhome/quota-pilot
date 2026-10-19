#!/usr/bin/env bash
# publish.sh — 產生 snapshot、追加歷史，推到 gh-pages 分支（GitHub Pages 來源）。給 launchd 每 30 分鐘跑；不耗 LLM token。
#   --init     建立 gh-pages 孤兒分支的 worktree（.pages/，已 gitignore）並首次推送
#   --dry-run  只更新 .pages/ 不 commit／push（本機預覽：python3 -m http.server -d .pages）
# 網頁取 origin/main 的 site/（雲端合併的外觀改動自動上線；本機 site/ 未推的改動不會發佈）；fetch 失敗退回本機 site/。
#   安全：只同步不在本機執行的 site/；bin/ 等會在本機執行的程式碼一律由使用者看過 diff 後手動 git pull。
# 歷史 data/history.jsonl 只留 14 天；每列 t, mode, route, hub, override, card, ct, xt, cr, xr, c5, c7, cs, x5, x7, xs（ct／xt＝7d 等級 rich|ok|lean|tight，cr／xr＝週 reset epoch；override 以後各欄自 2026-10-15 起，舊列沒有）。資料沒變（同一個 generated_at 分鐘內）也會照推，失敗不重試（下一輪再推）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; P="$ROOT/.pages"; DRY=0
case "${1:-}" in
  --init)
    git -C "$ROOT" show-ref -q refs/heads/gh-pages || { git -C "$ROOT" worktree add --orphan -b gh-pages "$P" >/dev/null || exit 1; }
    [ -d "$P" ] || git -C "$ROOT" worktree add "$P" gh-pages >/dev/null || exit 1 ;;
  --dry-run) DRY=1 ;;
esac
[ -d "$P" ] || { echo "先跑 publish.sh --init" >&2; exit 1; }
mkdir -p "$P/data"
if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
  git -C "$ROOT" archive origin/main -- site ':(exclude)site/data' | tar -x -C "$P" --strip-components=1 || exit 1
else
  cp -R "$ROOT/site/." "$P/"
fi
touch "$P/.nojekyll"
snap="$("$ROOT/bin/snapshot.sh")" || exit 1
printf '%s\n' "$snap" > "$P/data/snapshot.json"
# 派工／直做次數（只有次數）；orchestrator 不在就沿用上一份
work="$("$ROOT/bin/work-stats.sh" 2>/dev/null)" && printf '%s\n' "$work" > "$P/data/work.json"
python3 -I - "$P/data/history.jsonl" "$snap" <<'PY'
import json, sys, time
f, snap = sys.argv[1], json.loads(sys.argv[2])
g = lambda o, *k: (o := o) and [o := (o or {}).get(x) for x in k][-1]
row = {"t": snap["generated_at"], "mode": int(snap["mode"].get("mode", 0)), "route": snap["mode"].get("route"), "hub": snap["mode"].get("hub"),
       "override": snap["mode"].get("override"), "card": snap["mode"].get("card"),
       "ct": snap["mode"].get("claude"), "xt": snap["mode"].get("codex"),
       "cr": g(snap, "claude", "week", "resets_at"), "xr": g(snap, "codex", "week", "resets_at"),
       "c5": g(snap, "claude", "five", "used"), "c7": g(snap, "claude", "week", "used"), "cs": g(snap, "claude", "surplus"),
       "x5": g(snap, "codex", "five", "used"), "x7": g(snap, "codex", "week", "used"), "xs": g(snap, "codex", "surplus")}
try: rows = [json.loads(l) for l in open(f) if l.strip()]
except FileNotFoundError: rows = []
rows = [r for r in rows if r["t"] >= time.time() - 14 * 86400] + [row]
open(f, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
[ $DRY = 1 ] && { echo "dry-run：已更新 $P"; exit 0; }
cd "$P" && git add -A && git commit -qm "data: $(date -u +%Y-%m-%dT%H:%MZ)" && git push -q origin gh-pages 2>&1 | tail -3
