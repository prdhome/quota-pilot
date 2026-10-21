#!/usr/bin/env bash
# bin/publish.sh 故障注入：寫歷史的 Python 失敗時應 exit 非 0 且不推 gh-pages；對照組正常推送 exit 0。
# 在暫存 ROOT 放 publish.sh＋假 snapshot.sh／work-stats.sh，.pages 推到本機 bare repo（無 origin main → 走本機 site/）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
setup() {  # $1=dir $2=snapshot 輸出
  local d="$1"; mkdir -p "$d/bin" "$d/site"; cp "$ROOT/bin/publish.sh" "$d/bin/"; echo '<html>' > "$d/site/index.html"
  printf '#!/usr/bin/env bash\necho %q\n' "$2" > "$d/bin/snapshot.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/work-stats.sh"
  chmod +x "$d/bin/"*.sh; git init -q "$d"
  git init -q --bare "$d/remote.git"; git init -q -b gh-pages "$d/.pages"
  git -C "$d/.pages" config user.email t@t; git -C "$d/.pages" config user.name t
  git -C "$d/.pages" commit -q --allow-empty -m init; git -C "$d/.pages" remote add origin "$d/remote.git"
  git -C "$d/.pages" push -q origin gh-pages 2>/dev/null
}
pushed() { git -C "$1/remote.git" rev-list --count gh-pages; }
good='{"generated_at": 9999999999, "mode": {"mode": "5"}}'
setup "$T/ok" "$good"; "$T/ok/bin/publish.sh" >/dev/null 2>&1; rc=$?
[[ $rc == 0 && $(pushed "$T/ok") == 2 ]] && echo "  ✅ 正常：exit 0 且推送" || { echo "  ❌ 正常 rc=$rc pushed=$(pushed "$T/ok")"; fail=1; }
setup "$T/bad" '{"generated_at": 1}'; "$T/bad/bin/publish.sh" >/dev/null 2>&1; rc=$?
[[ $rc != 0 && $(pushed "$T/bad") == 1 ]] && echo "  ✅ Python 失敗：exit 非 0 且未推送" || { echo "  ❌ Python 失敗 rc=$rc pushed=$(pushed "$T/bad")"; fail=1; }
exit $fail
