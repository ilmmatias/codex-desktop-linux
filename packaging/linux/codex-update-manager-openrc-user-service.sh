#!/bin/sh

SERVICE_NAME="${SERVICE_NAME:-codex-update-manager}"

codex_foreach_openrc_user() {
    command -v runuser >/dev/null 2>&1 || return 0
    command -v rc-service >/dev/null 2>&1 || return 0
    command -v getent >/dev/null 2>&1 || return 0

    for runtime_dir in /run/user/*; do
        [ -d "$runtime_dir" ] || continue
        uid="$(basename "$runtime_dir")"
        case "$uid" in ''|*[!0-9]*|0) continue ;; esac
        user_name="$(getent passwd "$uid" | cut -d: -f1 || true)"
        [ -n "$user_name" ] || continue
        "$@" "$user_name" "$runtime_dir"
    done
}

codex_run_openrc_user() {
    user_name="$1"
    runtime_dir="$2"
    shift 2
    runuser -u "$user_name" -- env XDG_RUNTIME_DIR="$runtime_dir" "$@"
}

codex_openrc_service_enabled() {
    codex_run_openrc_user "$1" "$2" rc-update --user show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE_NAME}([[:space:]]|$)"
}

codex_start_one_enabled_openrc_service() {
    user_name="$1"
    runtime_dir="$2"
    codex_openrc_service_enabled "$user_name" "$runtime_dir" || return 0
    codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" start || true
}

codex_start_enabled_user_service() {
    codex_foreach_openrc_user codex_start_one_enabled_openrc_service
}

codex_ensure_one_openrc_service_running() {
    user_name="$1"
    runtime_dir="$2"
    if codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" status >/dev/null 2>&1; then
        return 0
    fi
    if codex_openrc_service_enabled "$user_name" "$runtime_dir"; then
        codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" start || true
    else
        codex_run_openrc_user "$user_name" "$runtime_dir" rc-update --user add "$SERVICE_NAME" default || true
        codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" start || true
    fi
}

codex_ensure_user_service_running() {
    codex_foreach_openrc_user codex_ensure_one_openrc_service_running
}

codex_cleanup_one_openrc_service() {
    action="$1"
    user_name="$2"
    runtime_dir="$3"
    case "$action" in
        stop) codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" stop || true ;;
        disable|disable-now)
            codex_run_openrc_user "$user_name" "$runtime_dir" rc-service --user "$SERVICE_NAME" stop || true
            codex_run_openrc_user "$user_name" "$runtime_dir" rc-update --user del "$SERVICE_NAME" default || true
            ;;
    esac
}

codex_cleanup_user_service() {
    action="$1"
    codex_foreach_openrc_user codex_cleanup_one_openrc_service "$action"
    case "$action" in
        disable|disable-now) codex_remove_inactive_openrc_enablement ;;
    esac
}

codex_remove_inactive_openrc_enablement() {
    command -v getent >/dev/null 2>&1 || return 0
    getent passwd | while IFS=: read -r user_name _ uid _ _ home _; do
        case "$uid" in ''|*[!0-9]*|0) continue ;; esac
        [ -n "$home" ] && [ -d "$home" ] || continue
        link="$home/.config/rc/runlevels/default/$SERVICE_NAME"
        [ -L "$link" ] || continue
        rm -f -- "$link" || true
    done
}

codex_reload_user_managers() { :; }
