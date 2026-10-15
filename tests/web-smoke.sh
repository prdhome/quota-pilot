#!/usr/bin/env bash
# site/index.html 冒煙測試：把 tests/fixtures 每組情境做成暫存網站（site/ ＋ 假 data/），起靜態伺服器，用 Playwright（Chromium）逐一載入檢查。
# 需要 node；第一次跑會在 tests/web/ 安裝 playwright（npm ci），沒有 Playwright Chromium 時自動改用系統 Google Chrome（或 PW_CHANNEL=chrome 強制）；兩者都沒有才需 npx --prefix tests/web playwright install chromium
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; srv=""
trap '[ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$T"' EXIT
[ -d "$ROOT/tests/web/node_modules/playwright" ] || npm ci --prefix "$ROOT/tests/web" --no-audit --no-fund >/dev/null || exit 1
names=()
for f in "$ROOT"/tests/fixtures/*.json; do
  n="$(basename "$f" .json)"; names+=("$n")
  python3 -I "$ROOT/tests/lib/fixture.py" site "$n" "$T/www/$n" || { echo "❌ ${n}：產生假網站失敗"; exit 1; }
  rm -rf "$T/www/$n/state" "$T/www/$n/home"   # 只留網站會讀的 index.html 與 data/
done
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 -d "$T/www" >/dev/null 2>&1 & srv=$!
for _ in $(seq 50); do python3 -c "import urllib.request,sys; urllib.request.urlopen(sys.argv[1])" "http://127.0.0.1:$port/" 2>/dev/null && break; sleep 0.1; done
node "$ROOT/tests/web/smoke.mjs" "http://127.0.0.1:$port" "$ROOT/tests/fixtures" "${names[@]}"
