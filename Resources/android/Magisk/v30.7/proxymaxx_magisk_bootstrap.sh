#!/system/bin/sh

# Runs as a one-shot init service from the temporary Magisk ramdisk, in Magisk's root
# domain. The first adb `su` call cannot authorize itself, so this root process creates the
# exact Shell UID policy instead — after the user has already consented in the app.
#
# The policy that existed beforehand is kept in a root-only Magisk database record until
# Revert verifies that it has been put back.

MAGISK_TMP="${0%/*}"
MAGISK_BIN="$MAGISK_TMP/magisk"
POLICY_BACKUP_TABLE="proxymaxx_shell_policy_backup_v1"
POLICY_READY="$MAGISK_TMP/.proxymaxx-magisk-policy-ready"
SESSION_MARKER="$MAGISK_TMP/.proxymaxx-magisk-session"
BOOTSTRAP_LOG="$MAGISK_TMP/proxymaxx-magisk-bootstrap.log"
SHELL_UID="2000"

log_message() {
    printf '%s\n' "$1" >> "$BOOTSTRAP_LOG"
    chmod 0644 "$BOOTSTRAP_LOG" 2>/dev/null || true
}

is_unsigned_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

parse_policy_row() {
    local row="$1"
    local uid_field policy_field until_field logging_field notification_field

    IFS='|' read -r uid_field policy_field until_field logging_field notification_field <<EOF
$row
EOF
    original_uid="${uid_field#uid=}"
    original_policy="${policy_field#policy=}"
    original_until="${until_field#until=}"
    original_logging="${logging_field#logging=}"
    original_notification="${notification_field#notification=}"

    [[ "$uid_field" == uid=* && "$policy_field" == policy=* && \
       "$until_field" == until=* && "$logging_field" == logging=* && \
       "$notification_field" == notification=* ]] || return 1
    [[ "$original_uid" == "$SHELL_UID" ]] || return 1
    is_unsigned_integer "$original_policy" && \
        is_unsigned_integer "$original_until" && \
        is_unsigned_integer "$original_logging" && \
        is_unsigned_integer "$original_notification"
}

parse_policy_backup() {
    local backup="$1"
    local present_field policy_field until_field logging_field notification_field

    IFS='|' read -r present_field policy_field until_field logging_field notification_field <<EOF
$backup
EOF
    backup_present="${present_field#present=}"
    backup_policy="${policy_field#policy=}"
    backup_until="${until_field#until=}"
    backup_logging="${logging_field#logging=}"
    backup_notification="${notification_field#notification=}"

    [[ "$present_field" == present=* && "$policy_field" == policy=* && \
       "$until_field" == until=* && "$logging_field" == logging=* && \
       "$notification_field" == notification=* ]] || return 1
    [[ "$backup_present" == "0" || "$backup_present" == "1" ]] || return 1
    is_unsigned_integer "$backup_policy" && \
        is_unsigned_integer "$backup_until" && \
        is_unsigned_integer "$backup_logging" && \
        is_unsigned_integer "$backup_notification"
}

read_policy_backup() {
    local backup
    backup="$($MAGISK_BIN --sqlite \
        "SELECT present,policy,until,logging,notification FROM $POLICY_BACKUP_TABLE WHERE id=1;" \
        2>/dev/null)" || return 1
    [[ -n "$backup" ]] || return 1
    parse_policy_backup "$backup"
}

# Record the Shell UID row exactly as it was found, so it can be put back later. An
# unreadable or unrecognised row is never replaced: refusing is safer than destroying the
# only copy of the previous state.
save_original_policy() {
    "$MAGISK_BIN" --sqlite \
        "CREATE TABLE IF NOT EXISTS $POLICY_BACKUP_TABLE(id INTEGER PRIMARY KEY,present INTEGER NOT NULL,policy INTEGER NOT NULL,until INTEGER NOT NULL,logging INTEGER NOT NULL,notification INTEGER NOT NULL);" \
        >/dev/null 2>&1 || return 1

    local existing_backup
    existing_backup="$($MAGISK_BIN --sqlite \
        "SELECT present,policy,until,logging,notification FROM $POLICY_BACKUP_TABLE WHERE id=1;" \
        2>/dev/null)" || return 1
    if [[ -n "$existing_backup" ]]; then
        if parse_policy_backup "$existing_backup"; then
            return 0
        fi
        log_message "The persistent ProxyMaxx Shell policy recovery record is unreadable; refusing to replace it."
        return 1
    fi

    local original_row
    original_row="$($MAGISK_BIN --sqlite \
        "SELECT uid,policy,until,logging,notification FROM policies WHERE uid=$SHELL_UID;" \
        2>/dev/null)" || return 1

    if [[ -z "$original_row" ]]; then
        "$MAGISK_BIN" --sqlite \
            "INSERT INTO $POLICY_BACKUP_TABLE(id,present,policy,until,logging,notification) VALUES(1,0,0,0,0,0);" \
            >/dev/null 2>&1 || return 1
    elif parse_policy_row "$original_row"; then
        "$MAGISK_BIN" --sqlite \
            "INSERT INTO $POLICY_BACKUP_TABLE(id,present,policy,until,logging,notification) VALUES(1,1,$original_policy,$original_until,$original_logging,$original_notification);" \
            >/dev/null 2>&1 || return 1
    else
        log_message "Refusing to overwrite an unreadable existing Shell policy: $original_row"
        return 1
    fi
    read_policy_backup
}

restore_original_policy() {
    read_policy_backup || {
        log_message "No readable persistent ProxyMaxx Shell policy recovery record was found; leaving Magisk policy unchanged."
        return 1
    }

    local restored_row expected_row
    if [[ "$backup_present" == "0" ]]; then
        "$MAGISK_BIN" --sqlite "DELETE FROM policies WHERE uid=$SHELL_UID;" >/dev/null 2>&1 || return 1
        restored_row="$($MAGISK_BIN --sqlite \
            "SELECT uid,policy,until,logging,notification FROM policies WHERE uid=$SHELL_UID;" \
            2>/dev/null)" || return 1
        [[ -z "$restored_row" ]] || return 1
    else
        "$MAGISK_BIN" --sqlite \
            "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) VALUES($SHELL_UID,$backup_policy,$backup_until,$backup_logging,$backup_notification);" \
            >/dev/null 2>&1 || return 1
        restored_row="$($MAGISK_BIN --sqlite \
            "SELECT uid,policy,until,logging,notification FROM policies WHERE uid=$SHELL_UID;" \
            2>/dev/null)" || return 1
        expected_row="uid=$SHELL_UID|policy=$backup_policy|until=$backup_until|logging=$backup_logging|notification=$backup_notification"
        [[ "$restored_row" == "$expected_row" ]] || return 1
    fi

    "$MAGISK_BIN" --sqlite "DELETE FROM $POLICY_BACKUP_TABLE WHERE id=1;" >/dev/null 2>&1 || return 1
    "$MAGISK_BIN" --sqlite "DROP TABLE IF EXISTS $POLICY_BACKUP_TABLE;" >/dev/null 2>&1 || true
    rm -f "$POLICY_READY" "$SESSION_MARKER"
    log_message "Restored the original ADB Shell policy."
}

provision_shell_policy() {
    rm -f "$POLICY_READY" "$SESSION_MARKER"
    : > "$BOOTSTRAP_LOG"
    chmod 0644 "$BOOTSTRAP_LOG"

    local attempt policy
    attempt=0
    while [[ "$attempt" -lt 60 ]]; do
        # policy=2 is Magisk's "allow" for this UID. Only uid 2000 is written.
        if save_original_policy && \
           "$MAGISK_BIN" --sqlite \
               "INSERT OR REPLACE INTO policies(uid,policy,until,logging,notification) VALUES($SHELL_UID,2,0,1,0);" \
               >/dev/null 2>&1; then
            policy="$($MAGISK_BIN --sqlite \
                "SELECT policy FROM policies WHERE uid=$SHELL_UID;" 2>/dev/null)" || policy=""
            if [[ "$policy" == "policy=2" ]]; then
                : > "$POLICY_READY"
                : > "$SESSION_MARKER"
                chmod 0644 "$POLICY_READY"
                chmod 0600 "$SESSION_MARKER"
                log_message "ADB Shell UID $SHELL_UID root policy is ready."
                return 0
            fi
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    log_message "Timed out while provisioning the ADB Shell UID $SHELL_UID root policy."
    return 1
}

case "${1:-provision}" in
    provision)
        provision_shell_policy
        ;;
    restore)
        restore_original_policy
        ;;
    *)
        log_message "Unknown bootstrap command: $1"
        exit 2
        ;;
esac
