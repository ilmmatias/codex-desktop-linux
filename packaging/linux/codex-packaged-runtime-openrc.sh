#!/bin/bash

codex_packaged_runtime_prelaunch() {
    codex_packaged_runtime_prelaunch_background >/dev/null 2>&1 &
}

codex_packaged_runtime_prelaunch_background() {
    command -v rc-service >/dev/null 2>&1 || return 0
    command -v rc-update >/dev/null 2>&1 || return 0
    [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] || return 0

    # Starting is intentionally conditional. A package upgrade must not undo a
    # user's explicit `rc-update --user del` choice.
    if rc-update --user show default 2>/dev/null | grep -Eq '(^|[[:space:]])codex-update-manager([[:space:]]|$)'; then
        rc-service --user codex-update-manager start >/dev/null 2>&1 || true
        codex_packaged_runtime_trigger_update_check
    fi
}

codex_packaged_runtime_trigger_update_check() {
    command -v codex-update-manager >/dev/null 2>&1 || return 0
    codex-update-manager check-now --if-stale >/dev/null 2>&1 || true
}

codex_packaged_runtime_export_env() {
    export CHROME_DESKTOP="codex-desktop.desktop"
    export BAMF_DESKTOP_FILE_HINT="/usr/share/applications/codex-desktop.desktop"
}
