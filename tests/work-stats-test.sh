#!/usr/bin/env bash
# bin/work-stats.sh 測試：假 orchestrator tasks/，檢查 7 天視窗、測試任務排除、active 只給件數、輸出不含 task id。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tasks/active/secret-task-1"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); old=2020-01-01T00:00:00Z
printf 'recorded_at\tslug\tdomain\twall_s\tinterventions\toutcome\tissue\tverify\n%s\ta\to\t1\t0\tpass\t-\n%s\tb\to\t1\t0\tfail\t-\n%s\tc\to\t1\t0\tpass\t-\n%s\tsmoke-x\to\t1\t0\tpass\t-\n' "$now" "$now" "$old" "$now" > "$T/tasks/direct-log.tsv"
# 派工改由 orchestrator bin/fail-classify.py 算首次成功率（口徑測試在 orchestrator tests/fail-classify-test.sh）；這裡用替身確認有帶 --since 並照輸出回報
mkdir -p "$T/bin"; printf '#!/usr/bin/env python3\nimport sys\nassert "--summary" in sys.argv and sys.argv[sys.argv.index("--since") + 1].endswith("Z")\nprint("noise=1")\nprint("first_success=1/2")\n' > "$T/bin/fail-classify.py"
out="$(QP_ORCH="$T" "$ROOT/bin/work-stats.sh")" || { echo "  ❌ work-stats.sh 失敗"; exit 1; }
got=$(python3 -I -c 'import json,sys; s=json.loads(sys.argv[1]); print(s["direct"], s["dispatch"], s["active"])' "$out")
fail=0
[[ $got == "{'n': 2, 'ok': 1} {'n': 2, 'ok': 1, 'basis': 'first-attempt-per-task'} 1" ]] && echo "  ✅ 次數與 active 件數" || { echo "  ❌ got '$got'"; fail=1; }
[[ $out != *secret* ]] && echo "  ✅ 不含 task id" || { echo "  ❌ 輸出含 task id"; fail=1; }
QP_ORCH="$T/none" "$ROOT/bin/work-stats.sh" 2>/dev/null && { echo "  ❌ 缺目錄應失敗"; fail=1; } || echo "  ✅ 缺目錄 exit 非 0"
rm "$T/bin/fail-classify.py"
QP_ORCH="$T" "$ROOT/bin/work-stats.sh" >/dev/null 2>&1 && { echo "  ❌ 缺分類器應失敗（不退回按列計）"; fail=1; } || echo "  ✅ 缺分類器 exit 非 0"
exit $fail
