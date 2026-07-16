#!/bin/bash
# Removes GW Switch: stops/unloads the daemon and deletes all installed files.
# Requires admin (sudo) because it touches /Library and /usr/local.
set -e

PLIST="/Library/LaunchDaemons/com.gatewaytray.daemon.plist"
AGENT="/Library/LaunchAgents/com.gatewaytray.app.plist"
AGENT_LABEL="com.gatewaytray.app"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo…"
  exec sudo "$0" "$@"
fi

launchctl bootout system "$PLIST" 2>/dev/null || true

# Stop the login agent for the logged-in user, then remove it.
CONSOLE_USER=$(stat -f %Su /dev/console 2>/dev/null || true)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || true)
  [[ -n "$CONSOLE_UID" ]] && launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true
fi
pkill -x GWSwitch 2>/dev/null || true
pkill -x GatewayTray 2>/dev/null || true

rm -f "$PLIST"
rm -f "$AGENT"
rm -f /usr/local/libexec/gatewayd
rm -f /var/run/gatewaytray.sock /var/run/gatewaytray.prev
rm -rf /Applications/GWSwitch.app /Applications/GatewayTray.app

echo "Removed daemon, app, and LaunchDaemon."
echo "Per-user config left at ~/Library/Application Support/GatewayTray (remove manually if desired)."
echo "Log left at /var/log/gatewaytray.log"
