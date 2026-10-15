#!/usr/bin/env bash
# preview.sh — 用 tests/fixtures 的假資料在本機預覽儀表板（不讀真實額度、不推任何東西）。
#   bin/preview.sh                 列出情境
#   bin/preview.sh <情境> [port]   把 site/ 與該情境的假 data/ 放到暫存目錄，python3 -m http.server 開預覽（預設 port 8765，Ctrl-C 結束並清掉暫存）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { echo "用法：bin/preview.sh <情境> [port]"; python3 -I "$ROOT/tests/lib/fixture.py" list; exit 0; }
[ -f "$ROOT/tests/fixtures/$1.json" ] || { echo "沒有情境 $1；可用：" >&2; python3 -I "$ROOT/tests/lib/fixture.py" list >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
python3 -I "$ROOT/tests/lib/fixture.py" site "$1" "$T/www" || exit 1
rm -rf "$T/www/state" "$T/www/home"
port="${2:-8765}"
echo "預覽 $1：http://127.0.0.1:$port/   （Ctrl-C 結束）"
python3 -m http.server "$port" --bind 127.0.0.1 -d "$T/www"
