#!/usr/bin/env bash
# publish.sh — 產生 snapshot、追加歷史，推到 gh-pages 分支（GitHub Pages 來源）。給 launchd 每 30 分鐘跑；不耗 LLM token。
#   --init     建立 gh-pages 孤兒分支的 worktree（.pages/，已 gitignore）並首次推送
#   --dry-run  只更新 .pages/ 不 commit／push（本機預覽：python3 -m http.server -d .pages）
# 歷史 data/history.jsonl 只留 14 天。資料沒變（同一個 generated_at 分鐘內）也會照推，失敗不重試（下一輪再推）。
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
cp -R "$ROOT/site/." "$P/"
touch "$P/.nojekyll"
snap="$("$ROOT/bin/snapshot.sh")" || exit 1
printf '%s\n' "$snap" > "$P/data/snapshot.json"
python3 -I - "$P/data/history.jsonl" "$snap" <<'PY'
import json, sys, time
f, snap = sys.argv[1], json.loads(sys.argv[2])
g = lambda o, *k: (o := o) and [o := (o or {}).get(x) for x in k][-1]
row = {"t": snap["generated_at"], "mode": int(snap["mode"].get("mode", 0)), "route": snap["mode"].get("route"), "hub": snap["mode"].get("hub"),
       "c5": g(snap, "claude", "five", "used"), "c7": g(snap, "claude", "week", "used"), "cs": g(snap, "claude", "surplus"),
       "x5": g(snap, "codex", "five", "used"), "x7": g(snap, "codex", "week", "used"), "xs": g(snap, "codex", "surplus")}
try: rows = [json.loads(l) for l in open(f) if l.strip()]
except FileNotFoundError: rows = []
rows = [r for r in rows if r["t"] >= time.time() - 14 * 86400] + [row]
open(f, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
[ $DRY = 1 ] && { echo "dry-run：已更新 $P"; exit 0; }
cd "$P" && git add -A && git commit -qm "data: $(date -u +%Y-%m-%dT%H:%MZ)" && git push -q origin gh-pages 2>&1 | tail -3
