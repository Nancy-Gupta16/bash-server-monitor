#!/usr/bin/env bash
# =============================================================================
# monitor.sh - Linux server monitoring & alerting (main entry point)
#
# Usage: monitor.sh [--check-now] [--dry-run] [--test-alert] [--status]
#                   [--cleanup] [--config FILE] [-h|--help] [-V|--version]
#
# Exit codes: 0 = all OK, 1 = warnings, 2 = critical alerts, 3 = usage/config error
# =============================================================================
set -Eeuo pipefail

# Cron runs with a minimal PATH; pin a sane one. LC_ALL=C gives stable,
# parseable output from df/ps/ping and '.' decimal separators.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C
umask 027

readonly VERSION="1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_PATH BASE_DIR

# --- runtime state (overridden by arguments / config) ------------------------
MODE="run"                 # run | test | status | cleanup
DRY_RUN=false
FORCE_TERMINAL=false
TERMINAL_OUTPUT=false
LOG_TO_FILE=true
HOST_LABEL=""
RUN_STARTED=false
RUN_START_EPOCH=0
CONFIG_FILE="${MONITOR_CONF:-${BASE_DIR}/config/monitor.conf}"

for _lib in logger metrics alerts; do
    if [ ! -r "${BASE_DIR}/lib/${_lib}.sh" ]; then
        echo "FATAL: missing library ${BASE_DIR}/lib/${_lib}.sh" >&2
        exit 3
    fi
    # shellcheck source=/dev/null
    . "${BASE_DIR}/lib/${_lib}.sh"
done
unset _lib

# =============================================================================
# CLI
# =============================================================================
usage() {
    cat <<EOF
server-monitor ${VERSION} - Linux server monitoring and alerting

Usage: $(basename "$0") [options]

  (no options)     Run all checks quietly (this is what cron executes)
  --check-now      Run all checks immediately with live terminal output
  --dry-run        Run all checks; print what WOULD be sent. Sends nothing,
                   writes no log entries and does not touch cool-down state
  --test-alert     Send a synthetic CRITICAL alert through every channel
  --status         Show alerts currently being throttled (active incidents)
  --cleanup        Rotate the log and delete logs older than the retention period
  --config FILE    Use FILE instead of config/monitor.conf
  -h, --help       Show this help
  -V, --version    Show version

Exit codes: 0 OK | 1 warnings | 2 critical | 3 usage/config error
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 3
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check-now)  FORCE_TERMINAL=true ;;
            --dry-run)    DRY_RUN=true ;;
            --test-alert) MODE="test" ;;
            --status)     MODE="status" ;;
            --cleanup)    MODE="cleanup" ;;
            --config)
                shift
                [ $# -gt 0 ] || die "--config requires a file argument"
                CONFIG_FILE="$1" ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "server-monitor ${VERSION}"; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done
}

# =============================================================================
# Configuration
# =============================================================================
load_config() {
    local mode var
    [ -r "$CONFIG_FILE" ] || die "Config file not readable: $CONFIG_FILE"

    mode=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 600)
    if [ $((8#$mode & 2)) -ne 0 ]; then
        die "Config file $CONFIG_FILE is world-writable (mode $mode); run: chmod 600 $CONFIG_FILE"
    fi

    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    : "${CPU_WARN:=80}"  "${CPU_CRIT:=95}"
    : "${MEM_WARN:=85}"  "${MEM_CRIT:=95}"
    : "${DISK_WARN:=85}" "${DISK_CRIT:=95}"
    : "${CPU_SAMPLE_SECONDS:=2}"
    : "${DISK_MOUNTS:=}"
    : "${DISK_EXCLUDE_FS:=tmpfs devtmpfs squashfs overlay iso9660 efivarfs}"
    : "${DISK_EXCLUDE_MOUNT_REGEX:=^/(snap|run|sys|proc|dev)(/|\$)}"
    : "${CRITICAL_SERVICES:=}"
    : "${PING_TARGETS:=gateway 1.1.1.1}"
    : "${PING_COUNT:=3}" "${PING_TIMEOUT:=3}"
    : "${NET_LOSS_WARN:=25}" "${NET_LOSS_CRIT:=100}" "${NET_RTT_WARN_MS:=250}"
    : "${ALERT_COOLDOWN_MINUTES:=15}"
    : "${TOP_N:=5}"
    : "${WEBHOOK_URL:=}" "${WEBHOOK_TYPE:=slack}" "${WEBHOOK_TIMEOUT:=10}"
    : "${MAIL_TO:=}"
    : "${USE_SYSLOG:=true}"
    : "${HOSTNAME_LABEL:=}"
    : "${LOG_FILE:=${BASE_DIR}/logs/monitor.log}"
    : "${STATE_DIR:=${BASE_DIR}/state}"
    : "${LOG_RETENTION_DAYS:=7}"

    for var in CPU_WARN CPU_CRIT MEM_WARN MEM_CRIT DISK_WARN DISK_CRIT CPU_SAMPLE_SECONDS \
               PING_COUNT PING_TIMEOUT NET_LOSS_WARN NET_LOSS_CRIT NET_RTT_WARN_MS \
               ALERT_COOLDOWN_MINUTES TOP_N WEBHOOK_TIMEOUT LOG_RETENTION_DAYS; do
        is_number "${!var}" || die "Invalid numeric value for ${var} in ${CONFIG_FILE}: '${!var}'"
    done

    HOST_LABEL="${HOSTNAME_LABEL:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
}

# =============================================================================
# Signal / error / exit handling
# =============================================================================
on_error() {
    local rc=$1 line=$2
    trap - ERR
    log_error "Unexpected failure (exit=${rc}) at line ${line} in ${FUNCNAME[1]:-main}"
}

on_signal() {
    local sig=$1 code=$2
    trap - INT TERM HUP
    log_warn "Received SIG${sig}; aborting run"
    exit "$code"
}

on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$RUN_STARTED" = true ]; then
        log_info "Run finished: exit=${rc} critical=${ALERTS_CRIT} warn=${ALERTS_WARN} duration=$(($(date +%s) - RUN_START_EPOCH))s"
    fi
    exit "$rc"
}

install_traps() {
    trap 'on_error $? $LINENO' ERR
    trap 'on_signal INT 130' INT
    trap 'on_signal TERM 143' TERM
    trap 'on_signal HUP 129' HUP
    trap on_exit EXIT
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$STATE_DIR"
    exec 9> "${STATE_DIR}/monitor.lock"
    if ! flock -n 9; then
        log_warn "Another monitor.sh instance is still running; skipping this run"
        exit 0
    fi
}

# =============================================================================
# Threshold evaluation
# =============================================================================
# evaluate_usage <key> <metric> <value> <warn> <crit> <label>
evaluate_usage() {
    local key=$1 metric=$2 value=$3 warn=$4 crit=$5 label=$6

    if ! is_number "$value"; then
        log_error "Could not read ${metric}: got '${value}'"
        return 0
    fi

    if float_gt "$value" "$crit"; then
        alert_raise CRITICAL "$key" "$metric" "${value}%" "${crit}%" "${label} is ${value}% (critical > ${crit}%)"
    elif float_gt "$value" "$warn"; then
        alert_raise WARN "$key" "$metric" "${value}%" "${warn}%" "${label} is ${value}% (warning > ${warn}%)"
    else
        log_event INFO "$metric" "${value}%" "${warn}%" "${label} is within limits"
        alert_clear "$key" "$metric" "${label} is back to normal (${value}%)"
    fi
}

check_cpu() {
    local value
    value=$(metric_cpu_usage)
    evaluate_usage "cpu" "cpu_usage" "$value" "$CPU_WARN" "$CPU_CRIT" "CPU usage"
}

check_memory() {
    local pct used free total
    read -r pct used free total <<< "$(metric_memory)"
    evaluate_usage "memory" "memory_usage" "$pct" "$MEM_WARN" "$MEM_CRIT" \
        "Memory usage (${used}MB used, ${free}MB available of ${total}MB)"
}

check_disks() {
    local pct mount
    local -a mounts=()

    if [ -n "${DISK_MOUNTS// /}" ]; then
        read -ra mounts <<< "$DISK_MOUNTS"
    fi

    while IFS=$'\t' read -r pct mount; do
        if [ -z "${pct:-}" ] || [ -z "${mount:-}" ]; then continue; fi
        if [ ${#mounts[@]} -eq 0 ] && [[ "$mount" =~ $DISK_EXCLUDE_MOUNT_REGEX ]]; then continue; fi
        evaluate_usage "disk:${mount}" "disk_usage:${mount}" "$pct" "$DISK_WARN" "$DISK_CRIT" \
            "Disk usage on ${mount}"
    done < <(metric_disk_usage ${mounts[@]+"${mounts[@]}"})
}

check_services() {
    local svc state

    if [ -z "${CRITICAL_SERVICES// /}" ]; then
        log_info "No critical services configured; skipping service checks"
        return 0
    fi

    for svc in $CRITICAL_SERVICES; do
        state=$(metric_service_status "$svc")
        case "$state" in
            active)
                log_event INFO "service_${svc}" "$state" "active" "Service ${svc} is running"
                alert_clear "service:${svc}" "service_${svc}" "Service ${svc} is running again"
                ;;
            not-found)
                alert_raise WARN "service:${svc}" "service_${svc}" "$state" "active" \
                    "Service ${svc} not found on this host (check CRITICAL_SERVICES)"
                ;;
            activating|reloading)
                alert_raise WARN "service:${svc}" "service_${svc}" "$state" "active" \
                    "Service ${svc} is ${state}"
                ;;
            *)
                alert_raise CRITICAL "service:${svc}" "service_${svc}" "$state" "active" \
                    "Service ${svc} is ${state}"
                ;;
        esac
    done
}

check_network() {
    local target label key res loss rtt

    for target in $PING_TARGETS; do
        key="net:${target}"
        if [ "$target" = "gateway" ]; then
            key="net:gateway"
            target=$(metric_default_gateway)
            if [ -z "$target" ]; then
                alert_raise CRITICAL "$key" "network_gateway" "none" "present" \
                    "No default gateway/route configured"
                continue
            fi
            label="gateway ${target}"
        else
            label="$target"
        fi

        res=$(metric_ping "$target")
        read -r loss rtt <<< "$res"

        if [ "$loss" = "unavailable" ]; then
            log_warn "'ping' is not installed; skipping network checks"
            return 0
        fi

        if float_ge "$loss" "$NET_LOSS_CRIT"; then
            alert_raise CRITICAL "$key" "ping_loss" "${loss}%" "${NET_LOSS_CRIT}%" \
                "${label} is unreachable (${loss}% packet loss)"
        elif float_ge "$loss" "$NET_LOSS_WARN"; then
            alert_raise WARN "$key" "ping_loss" "${loss}%" "${NET_LOSS_WARN}%" \
                "Packet loss to ${label} is ${loss}%"
        elif is_number "$rtt" && float_gt "$rtt" "$NET_RTT_WARN_MS"; then
            alert_raise WARN "$key" "ping_rtt" "${rtt}ms" "${NET_RTT_WARN_MS}ms" \
                "High latency to ${label}: ${rtt}ms"
        else
            log_event INFO "ping_${target}" "loss=${loss}% rtt=${rtt}ms" "${NET_LOSS_WARN}%" \
                "${label} reachable"
            alert_clear "$key" "ping_loss" "${label} is reachable again"
        fi
    done
}

# =============================================================================
# Modes
# =============================================================================
# Run a check in isolation: one failing check must never stop the others.
run_check() {
    if ! "$@"; then
        log_error "Check '$1' failed unexpectedly; continuing with the remaining checks"
    fi
}

mode_run() {
    local rc=0
    RUN_STARTED=true
    RUN_START_EPOCH=$(date +%s)

    if [ "$DRY_RUN" != true ]; then
        acquire_lock
        log_cleanup
    else
        printf '*** DRY RUN: nothing is sent, logged or written to cool-down state ***\n'
    fi

    log_info "Run started (version ${VERSION}, dry_run=${DRY_RUN}, pid=$$)"

    run_check check_cpu
    run_check check_memory
    run_check check_disks
    run_check check_services
    run_check check_network

    if [ "$ALERTS_CRIT" -gt 0 ]; then
        rc=2
    elif [ "$ALERTS_WARN" -gt 0 ]; then
        rc=1
    fi

    if [ "$TERMINAL_OUTPUT" = true ]; then
        printf '\nSummary: %s critical, %s warning alert(s) on %s\n' "$ALERTS_CRIT" "$ALERTS_WARN" "$HOST_LABEL"
    fi
    exit "$rc"
}

mode_test() {
    TERMINAL_OUTPUT=true
    printf 'Channels: webhook=%s (%s)  mail=%s  syslog=%s  log=%s\n' \
        "$([ -n "$WEBHOOK_URL" ] && echo configured || echo off)" "$WEBHOOK_TYPE" \
        "${MAIL_TO:-off}" "$USE_SYSLOG" "$([ "$LOG_TO_FILE" = true ] && echo "$LOG_FILE" || echo off)"
    if alert_send_test; then
        exit 0
    fi
    exit 1
}

mode_status() {
    local f ts sev first key now n=0
    now=$(date +%s)
    printf 'Host: %s | cool-down: %sm | state dir: %s\n\n' "$HOST_LABEL" "$ALERT_COOLDOWN_MINUTES" "$STATE_DIR"

    shopt -s nullglob
    for f in "$STATE_DIR"/alert_*.state; do
        key=""
        read -r ts sev first key < "$f" || continue
        printf '%-9s %-28s firing for %-8s last notified %s\n' \
            "$sev" "${key:-$f}" "$(_fmt_duration $((now - first)))" "$(date -d "@${ts}" '+%F %T')"
        n=$((n + 1))
    done
    shopt -u nullglob

    if [ "$n" -eq 0 ]; then
        echo "No active alerts."
    fi
    exit 0
}

mode_cleanup() {
    acquire_lock
    log_cleanup
    alert_state_prune
    log_info "Cleanup finished (retention ${LOG_RETENTION_DAYS} days)"
    exit 0
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    load_config

    if [ "$FORCE_TERMINAL" = true ] || [ "$DRY_RUN" = true ] || [ -t 1 ]; then
        TERMINAL_OUTPUT=true
    fi
    if [ "$DRY_RUN" = true ] || [ "$MODE" = status ]; then
        LOG_TO_FILE=false
    fi

    log_init
    install_traps

    case "$MODE" in
        run)     mode_run ;;
        test)    mode_test ;;
        status)  mode_status ;;
        cleanup) mode_cleanup ;;
        *)       die "Internal error: unknown mode '$MODE'" ;;
    esac
}

main "$@"
