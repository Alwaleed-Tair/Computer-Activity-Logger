#!/usr/bin/env bash
# =============================================================================
# tests/usermgr.sh — a REAL systemd user manager for the service tests
# -----------------------------------------------------------------------------
# TEST INFRASTRUCTURE ONLY. The product itself never needs root, sudo, useradd or any of this.
#
# The service tests must exercise the real thing: `systemd --user` reading our unit file.
#   native  : you are a normal user on a machine with a user manager (a real Ubuntu login):
#             we simply use it, with a uniquely named unit, so your own services are untouched.
#   private : we are root in a container whose PID 1 is not systemd (like this CI/sandbox).
#             We create a throw-away unprivileged user and start `systemd --user` for it,
#             inside a PRIVATE mount namespace in which only two things differ: a cgroup2
#             hierarchy is mounted (so the unprivileged manager can use cgroups) and
#             /run/systemd/system exists (systemd refuses to run otherwise). Nothing outside
#             that namespace changes.
# What this cannot reproduce: logind, PAM and a graphical session. "Login" is emulated by
# restarting the user manager, which is exactly what logind does when you log in or out.
# =============================================================================

UM_MODE=""            # native | private | "" (unavailable)
UM_USER="" UM_UID="" UM_HOME=""
UM_MGR_PID=""         # private mode: pid whose mount namespace the manager lives in
UM_CREATED_USER=0
UM_LOG=""

um_have() { command -v "$1" >/dev/null 2>&1; }

# um_detect — decide the mode. Returns 1 (with UM_WHY) if no real manager can be had.
um_detect() {
    UM_WHY=""
    if (( EUID != 0 )) && um_have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
        UM_MODE=native; UM_USER=$(id -un); UM_UID=$EUID; UM_HOME=$HOME; return 0
    fi
    if (( EUID != 0 )); then UM_WHY="not root and no systemd user manager is reachable"; return 1; fi
    if [[ -d /run/systemd/system ]]; then UM_WHY="root on a systemd machine: use a normal user (a root user manager is not what the product targets)"; return 1; fi
    local c
    for c in unshare nsenter runuser useradd userdel systemd systemctl; do
        if ! um_have "$c"; then UM_WHY="missing tool: $c"; return 1; fi
    done
    if ! unshare --mount --propagation private true 2>/dev/null; then UM_WHY="cannot create a mount namespace"; return 1; fi
    UM_MODE=private
}

# um_run CMD… — run CMD as the service user, where its systemd user manager is visible.
um_run() {
    if [[ $UM_MODE == native ]]; then "$@"; return; fi
    nsenter -m -t "$UM_MGR_PID" runuser -u "$UM_USER" -- \
        env XDG_RUNTIME_DIR="/run/user/$UM_UID" HOME="$UM_HOME" LANG=C.UTF-8 PATH="$PATH" "$@"
}
um_ctl() { um_run systemctl --user "$@"; }

# um_setup DIR — create the user (private mode) and start its manager. DIR = scratch for logs.
um_setup() {
    UM_LOG=$1/usermgr.log
    if [[ $UM_MODE == native ]]; then return 0; fi
    UM_USER="caltest$$"
    useradd -m -s /bin/bash "$UM_USER" || return 1
    UM_CREATED_USER=1
    UM_UID=$(id -u "$UM_USER"); UM_HOME=$(getent passwd "$UM_USER" | cut -d: -f6)
    um_start_manager
}

# um_start_manager — (re)start the user's systemd manager; returns when it is up.
um_start_manager() {
    local i state
    [[ $UM_MODE == private ]] || return 0
    mkdir -p "/run/user/$UM_UID" && chown "$UM_USER" "/run/user/$UM_UID" && chmod 700 "/run/user/$UM_UID"
    (
        unshare --mount --propagation private bash -c '
            user=$1 uid=$2 home=$3
            mount -t cgroup2 none /sys/fs/cgroup || exit 10
            mkdir -p /run/systemd && mount -t tmpfs none /run/systemd && mkdir -p /run/systemd/system
            mkdir -p "/sys/fs/cgroup/$user" && chown -R "$user" "/sys/fs/cgroup/$user"
            echo $$ > "/sys/fs/cgroup/$user/cgroup.procs" || exit 11
            exec runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" HOME="$home" LANG=C.UTF-8 systemd --user
        ' _ "$UM_USER" "$UM_UID" "$UM_HOME" >>"$UM_LOG" 2>&1 &
        echo $! >"$UM_LOG.pid"
    )
    UM_MGR_PID=$(cat "$UM_LOG.pid")
    for (( i = 0; i < 60; i++ )); do
        state=$(um_ctl is-system-running 2>/dev/null || true)
        if [[ $state == running || $state == degraded ]]; then return 0; fi
        sleep 0.25
    done
    return 1
}

# um_stop_manager — what logout does: ask the manager to exit (it stops every unit first).
um_stop_manager() {
    local i
    [[ $UM_MODE == private ]] || return 0
    um_ctl exit >/dev/null 2>&1 || true
    for (( i = 0; i < 60; i++ )); do
        if ! kill -0 "$UM_MGR_PID" 2>/dev/null; then return 0; fi
        sleep 0.25
    done
    um_kill_user_processes
}

# um_kill_user_processes — SIGKILL everything the throw-away user owns (private mode only).
um_kill_user_processes() {
    local p
    [[ $UM_MODE == private && $UM_CREATED_USER == 1 && -n $UM_USER ]] || return 0
    for p in $(ps -u "$UM_USER" -o pid= 2>/dev/null); do kill -KILL "$p" 2>/dev/null || true; done
}

# um_cleanup — remove everything um_setup created.
um_cleanup() {
    [[ $UM_MODE == private && $UM_CREATED_USER == 1 ]] || return 0
    um_stop_manager
    um_kill_user_processes
    sleep 0.3
    userdel -r "$UM_USER" >/dev/null 2>&1 || userdel -f -r "$UM_USER" >/dev/null 2>&1 || true
    if [[ -n $UM_UID && $UM_UID -gt 999 ]]; then rm -rf -- "/run/user/$UM_UID"; fi
    UM_CREATED_USER=0
}

# um_install_project DEST NAME — copy the project into DEST (inside the user's home) as a
# user would after cloning it, with a config.local.sh that sets the unit NAME and a fast scan.
um_install_project() {
    local dest=$1 name=$2 root=$3
    mkdir -p "$dest" || return 1
    cp -r "$root"/main.sh "$root"/config.sh "$root"/lib "$root"/conf "$root"/install "$root"/docs "$dest"/ || return 1
    printf 'INTERVAL_SEC=1\nMIN_DURATION_SEC=0\nSERVICE_NAME=%s\n' "$name" >"$dest/config.local.sh"
    if [[ $UM_MODE == private ]]; then chown -R "$UM_USER" "$dest"; fi
}
