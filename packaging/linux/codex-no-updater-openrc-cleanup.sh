#!/bin/sh

. /opt/codex-desktop/.codex-linux/codex-update-manager-openrc-user-service.sh 2>/dev/null || true

codex_no_updater_transition_cleanup() {
    if command -v codex_cleanup_user_service >/dev/null 2>&1; then
        codex_cleanup_user_service disable-now
    fi
}
