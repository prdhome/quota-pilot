#!/usr/bin/env bash
# install-launchd.sh — 安裝每 30 分鐘跑 publish.sh 的 launchd 任務（只在 Mac 開機且登入時跑）。`--uninstall` 移除。
# 用 /bin/bash 執行且 PATH 以 /usr/bin:/bin 開頭：repo 在 ~/Documents 時，macOS 隱私保護只放行已授權的 /bin/bash（Homebrew bash 會 Operation not permitted）。
L="com.quota-pilot.publish"; F="$HOME/Library/LaunchAgents/$L.plist"; ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = --uninstall ]; then launchctl bootout "gui/$(id -u)/$L" 2>/dev/null; rm -f "$F"; echo "已移除"; exit 0; fi
cat > "$F" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$L</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ROOT/bin/publish.sh</string></array>
  <key>StartInterval</key><integer>1800</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:$(dirname "$(command -v git)"):$(dirname "$(command -v codex 2>/dev/null || echo /usr/bin/true)")</string></dict>
  <key>StandardOutPath</key><string>$ROOT/.pages-publish.log</string>
  <key>StandardErrorPath</key><string>$ROOT/.pages-publish.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$L" 2>/dev/null; launchctl bootstrap "gui/$(id -u)" "$F" && echo "已安裝：每 30 分鐘推送，log 在 $ROOT/.pages-publish.log"
