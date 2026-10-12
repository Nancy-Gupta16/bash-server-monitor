#!/usr/bin/env bash
# =============================================================================
# lib/logger.sh - Centralised structured logging, rotation and cleanup
#
# Log line format (pipe-delimited, ISO-8601 timestamp, key=value fields):
#
#   2026-10-11T14:03:22+00:00 | CRITICAL | host=web01 | metric=cpu_usage | value=97.3% | threshold=95% | message="CPU usage is 97.3%"
#
# Severities: INFO, WARN, CRITICAL (alerts) and ERROR (problems in the tool
# itself, e.g. webhook failure).
#
# Globals consumed:
#   LOG_FILE, LOG_RETENTION_DAYS, LOG_TO_FILE, TERMINAL_OUTPUT, HOST_LABEL
# =============================================================================

if [ -n "${_LOGGER_SH_LOADED:-}" ]; then return 0; fi
_LOGGER_SH_LOADED=1

USE_COLOR=false

# log_init: prepare the log file and detect colour support.
log_init() {
    : "${LOG_TO_FILE:=true}"
    USE_COLOR=false
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        USE_COLOR=true
    fi

    if [ "$LOG_TO_FILE" = true ]; then
        local dir
        dir=$(dirname "$LOG_FILE")
        # Create the file only if missing: touching an existing file would reset
        # its mtime and defeat the day-based rotation in log_rotate.
        if ! { mkdir -p "$dir" && { [ -e "$LOG_FILE" ] || : > "$LOG_FILE"; } && [ -w "$LOG_FILE" ]; } 2>/dev/null; then
            echo "WARNING: cannot write to $LOG_FILE - logging to terminal/syslog only" >&2
            LOG_TO_FILE=false
        else
            chmod 640 "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# log_color <LEVEL>: print the ANSI colour sequence for a severity.
log_color() {
    if [ "$USE_COLOR" != true ]; then return 0; fi
    case "$1" in
        CRITICAL) printf '\033[1;31m' ;;
        WARN)     printf '\033[1;33m' ;;
        ERROR)    printf '\033[1;35m' ;;
        INFO|RECOVERED) printf '\033[0;32m' ;;
        *) ;;
    esac
}

log_reset() {
    if [ "$USE_COLOR" = true ]; then printf '\033[0m'; fi
}

# log_event <LEVEL> <metric> <value> <threshold> <message>
# Use "-" for fields that do not apply.
log_event() {
    local level=$1 metric=${2:--} value=${3:--} threshold=${4:--} message=${5:-}
    local ts line host="${HOST_LABEL:-unknown}"

    ts=$(date +%Y-%m-%dT%H:%M:%S%:z)
    message=${message//$'\n'/ }
    message=${message//\"/\'}

    printf -v line '%s | %-8s | host=%s | metric=%s | value=%s | threshold=%s | message="%s"' \
        "$ts" "$level" "$host" "$metric" "$value" "$threshold" "$message"

    if [ "${LOG_TO_FILE:-true}" = true ]; then
        printf '%s\n' "$line" 2>/dev/null >> "$LOG_FILE" || true
    fi

    if [ "${TERMINAL_OUTPUT:-false}" = true ]; then
        printf '%s %s%-8s%s %-18s %s\n' \
            "$(date +%T)" "$(log_color "$level")" "$level" "$(log_reset)" "$metric" "$message"
    elif [ "$level" = ERROR ]; then
        # Under cron there is no terminal: surface tool errors on stderr so they
        # end up in cron.log.
        printf '%s\n' "$line" >&2
    fi
}

# Convenience wrappers for messages that are not tied to a metric.
log_info()     { log_event INFO     system - - "$*"; }
log_warn()     { log_event WARN     system - - "$*"; }
log_critical() { log_event CRITICAL system - - "$*"; }
log_error()    { log_event ERROR    system - - "$*"; }

# log_rotate: move the current log aside when it was last written on an
# earlier calendar day. Rotated files are named <log>.YYYY-MM-DD(.gz).
log_rotate() {
    [ -f "$LOG_FILE" ] || return 0
    [ -s "$LOG_FILE" ] || return 0

    local today file_day rotated
    today=$(date +%F)
    file_day=$(date -r "$LOG_FILE" +%F)
    [ "$file_day" != "$today" ] || return 0

    rotated="${LOG_FILE}.${file_day}"
    # Copy-truncate keeps the same inode and preserves the original mtime of the
    # data, so retention is computed from the day the entries were written.
    cat "$LOG_FILE" >> "$rotated"
    touch -r "$LOG_FILE" "$rotated"
    : > "$LOG_FILE"
    if command -v gzip >/dev/null 2>&1 && gzip -f "$rotated"; then
        rotated="${rotated}.gz"
    fi
    log_info "Rotated previous log to ${rotated}"
}

# log_cleanup: rotate, delete rotated logs older than LOG_RETENTION_DAYS and
# cap the size of cron.log (stdout/stderr captured from cron).
log_cleanup() {
    local dir base removed size
    dir=$(dirname "$LOG_FILE")
    base=$(basename "$LOG_FILE")
    [ -d "$dir" ] || return 0

    log_rotate

    removed=$(find "$dir" -maxdepth 1 -type f -name "${base}.*" \
        -mtime "+${LOG_RETENTION_DAYS}" -print -delete 2>/dev/null | wc -l || true)
    removed=${removed//[[:space:]]/}
    if [ "${removed:-0}" -gt 0 ]; then
        log_info "Log cleanup: removed ${removed} file(s) older than ${LOG_RETENTION_DAYS} days"
    fi

    if [ -f "$dir/cron.log" ]; then
        size=$(stat -c %s "$dir/cron.log" 2>/dev/null || echo 0)
        if [ "$size" -gt 1048576 ]; then
            tail -n 500 "$dir/cron.log" > "$dir/cron.log.tmp" && cat "$dir/cron.log.tmp" > "$dir/cron.log"
            rm -f "$dir/cron.log.tmp"
            log_info "Truncated cron.log (was ${size} bytes)"
        fi
    fi
}
