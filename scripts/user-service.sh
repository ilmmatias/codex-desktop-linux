#!/bin/bash
set -Eeuo pipefail

action="${1:-status}"
service="codex-update-manager"

if [ -x "/etc/user/init.d/$service" ] && command -v rc-service >/dev/null 2>&1; then
    case "$action" in
        enable) rc-update --user add "$service" default; rc-service --user "$service" start ;;
        status) rc-service --user "$service" status ;;
        start) rc-service --user "$service" start ;;
        stop) rc-service --user "$service" stop ;;
        disable) rc-service --user "$service" stop || true; rc-update --user del "$service" default ;;
        *) echo "Unsupported service action: $action" >&2; exit 2 ;;
    esac
elif command -v systemctl >/dev/null 2>&1; then
    case "$action" in
        enable) systemctl --user daemon-reload; systemctl --user enable --now "$service.service" ;;
        status) systemctl --user status "$service.service" --no-pager ;;
        start|stop|disable) systemctl --user "$action" "$service.service" ;;
        *) echo "Unsupported service action: $action" >&2; exit 2 ;;
    esac
else
    echo "No supported user service manager is available" >&2
    exit 1
fi
