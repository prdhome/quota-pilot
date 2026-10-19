#!/usr/bin/env bash
# bin/work-stats.sh 測試：假 orchestrator tasks/，檢查 7 天視窗、測試任務排除、active 只給件數、輸出不含 task id。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tasks/active/secret-task-1"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); old=2020-01-01T00:00:00Z
printf 'recorded_at\tslug\tdomain\twall_s\tinterventions\toutcome\tissue\tverify\n%s\ta\to\t1\t0\tpass\t-\n%s\tb\to\t1\t0\tfail\t-\n%s\tc\to\t1\t0\tpass\t-\n%s\tsmoke-x\to\t1\t0\tpass\t-\n' "$now" "$now" "$old" "$now" > "$T/tasks/direct-log.tsv"
printf 'h\n%s\tsecret-task-2\tf\thigh\tclaude\tfalse\t3s\tpass\t0\n' "$now" > "$T/tasks/metrics.tsv"
out="$(QP_ORCH="$T" "$ROOT/bin/work-stats.sh")" || { echo "  ❌ work-stats.sh 失敗"; exit 1; }
got=$(python3 -I -c 'import json,sys; s=json.loads(sys.argv[1]); print(s["direct"], s["dispatch"], s["active"])' "$out")
fail=0
[[ $got == "{'n': 2, 'ok': 1} {'n': 1, 'ok': 1} 1" ]] && echo "  ✅ 次數與 active 件數" || { echo "  ❌ got '$got'"; fail=1; }
[[ $out != *secret* ]] && echo "  ✅ 不含 task id" || { echo "  ❌ 輸出含 task id"; fail=1; }
QP_ORCH="$T/none" "$ROOT/bin/work-stats.sh" 2>/dev/null && { echo "  ❌ 缺目錄應失敗"; fail=1; } || echo "  ✅ 缺目錄 exit 非 0"
exit $fail
