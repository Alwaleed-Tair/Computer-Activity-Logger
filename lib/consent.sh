#!/usr/bin/env bash
# =============================================================================
# lib/consent.sh — Explicit user consent (no consent => no logging)
# =============================================================================

# Print what is collected and what is NOT (shown before consent is recorded).
consent_notice() {
    cat <<EOF
================================================================
 Computer Activity Logger v${CAL_VERSION} — consent notice
================================================================
This program will record, for user '${CAL_USER}' ONLY:
  - when each usage session starts and ends
  - the NAME of each process you start/stop, with start/end time and duration

It will NEVER record:
  - keystrokes, passwords, clipboard, screen or file contents
  - window titles, browsing history, command-line arguments
  - anything about other users; nothing is sent over the network

Where your data lives:   ${DATA_DIR}
How to see the status:   ./main.sh status
How to stop logging:     ./main.sh stop
How to delete the data:  ./main.sh purge --all
How to withdraw consent: ./main.sh consent --revoke
================================================================
EOF
}

# True when a valid consent record exists for the current user.
consent_is_granted() {
    [[ -r $CONSENT_FILE ]] && grep -qx "user=${CAL_USER}" "$CONSENT_FILE" 2>/dev/null
}

# Write the consent record (private file).
consent_grant() {
    local ts
    printf -v ts '%(%F %T)T' -1
    printf 'user=%s\ngranted_at=%s\nversion=%s\n' "$CAL_USER" "$ts" "$CAL_VERSION" >"$CONSENT_FILE" || return 1
    chmod 600 "$CONSENT_FILE" 2>/dev/null || true
    log_info "consent granted by $CAL_USER"
}

consent_revoke() {
    rm -f -- "$CONSENT_FILE"
    log_info "consent revoked by $CAL_USER"
}

# Ask interactively (the user must type exactly "yes").
consent_prompt() {
    local answer=""
    consent_notice
    if [[ ! -t 0 ]]; then
        echo "Not an interactive terminal. Re-run with: ./main.sh consent --accept" >&2
        return 1
    fi
    read -r -p "Do you agree to this logging? Type 'yes' to continue: " answer
    if [[ $answer == yes ]]; then
        consent_grant
    else
        echo "Consent not given. Nothing was enabled."
        return 1
    fi
}

# Gate used by the daemon: fail loudly when there is no consent.
consent_require() {
    if consent_is_granted; then return 0; fi
    log_err "no consent on record for '$CAL_USER' — run: ./main.sh consent"
    return 1
}
