#!/usr/bin/env bash
# =============================================================================
# lib/alerts.sh - Alert formatting, throttling / de-duplication and delivery
#
# Delivery pipeline for every notification:
#   1. Log file entry (always, written by logger.sh)
#   2. Formatted terminal block (when TERMINAL_OUTPUT=true)
#   3. Webhook (Slack / Discord / generic JSON) via curl
#   4. Local mail fallback - only when no webhook is set or the webhook failed
#   5. Syslog (when USE_SYSLOG=true)
#
# Throttling: each alert has a key (e.g. "cpu", "disk:/var", "service:nginx").
# After a notification is delivered, a state file records <epoch> <severity>
# <first_seen_epoch> <key>. An identical alert is suppressed until
# ALERT_COOLDOWN_MINUTES have passed. An escalation (WARN -> CRITICAL) bypasses
# the cool-down. When the metric returns to normal the state is cleared and a
# RECOVERED notification is sent.
#
# Globals consumed: STATE_DIR, ALERT_COOLDOWN_MINUTES, WEBHOOK_URL, WEBHOOK_TYPE,
#   WEBHOOK_TIMEOUT, MAIL_TO, USE_SYSLOG, HOST_LABEL, DRY_RUN, TERMINAL_OUTPUT
# =============================================================================

if [ -n "${_ALERTS_SH_LOADED:-}" ]; then return 0; fi
_ALERTS_SH_LOADED=1

ALERTS_WARN=0
ALERTS_CRIT=0
ST_LAST=""
ST_SEV=""
ST_FIRST=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_sev_rank() {
    case "$1" in
        CRITICAL) echo 2 ;;
        WARN)     echo 1 ;;
        *)        echo 0 ;;
    esac
}

_state_file() {
    printf '%s/alert_%s.state' "$STATE_DIR" "${1//[^A-Za-z0-9._-]/_}"
}

_fmt_duration() {
    local s=$1
    if [ "$s" -lt 60 ]; then
        printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then
        printf '%dm' $((s / 60))
    else
        printf '%dh %dm' $((s / 3600)) $(((s % 3600) / 60))
    fi
}

# json_escape <text>: escape text for embedding inside a JSON string.
json_escape() {
    printf '%s' "$1" \
        | tr -d '\000-\010\013-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
        | sed ':a;N;$!ba;s/\n/\\n/g'
}

# ---------------------------------------------------------------------------
# State handling (throttling)
# ---------------------------------------------------------------------------
# _state_read <key>: loads ST_LAST / ST_SEV / ST_FIRST. Fails if no state.
_state_read() {
    local f
    f=$(_state_file "$1")
    ST_LAST=""
    ST_SEV=""
    ST_FIRST=""
    [ -f "$f" ] || return 1
    read -r ST_LAST ST_SEV ST_FIRST _ < "$f" || return 1
    [[ "$ST_LAST" =~ ^[0-9]+$ ]] || return 1
    [[ "$ST_FIRST" =~ ^[0-9]+$ ]] || ST_FIRST=$ST_LAST
    return 0
}

_state_write() {
    local key=$1 sev=$2 first=$3 f tmp
    f=$(_state_file "$key")
    tmp="${f}.tmp.$$"
    mkdir -p "$STATE_DIR"
    printf '%s %s %s %s\n' "$(date +%s)" "$sev" "$first" "$key" > "$tmp" && mv -f "$tmp" "$f"
}

# alert_is_throttled <key> <severity>: success when the alert must be suppressed.
alert_is_throttled() {
    local key=$1 sev=$2 now cooldown
    _state_read "$key" || return 1
    if [ "$(_sev_rank "$sev")" -gt "$(_sev_rank "$ST_SEV")" ]; then
        return 1   # escalation: always notify
    fi
    now=$(date +%s)
    cooldown=$((ALERT_COOLDOWN_MINUTES * 60))
    [ $((now - ST_LAST)) -lt "$cooldown" ]
}

# alert_state_prune: remove state files untouched for LOG_RETENTION_DAYS.
alert_state_prune() {
    [ -d "$STATE_DIR" ] || return 0
    find "$STATE_DIR" -maxdepth 1 -type f -name 'alert_*.state' \
        -mtime "+${LOG_RETENTION_DAYS:-7}" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
# _build_body <sev> <metric> <value> <threshold> <detail> <firing_for> <top>
_build_body() {
    local sev=$1 metric=$2 value=$3 threshold=$4 detail=$5 firing=$6 top=$7
    printf 'Host:       %s\n' "$HOST_LABEL"
    printf 'Time:       %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Severity:   %s\n' "$sev"
    printf 'Metric:     %s\n' "$metric"
    printf 'Value:      %s\n' "$value"
    printf 'Threshold:  %s\n' "$threshold"
    printf 'Detail:     %s\n' "$detail"
    if [ -n "$firing" ]; then
        printf 'Firing for: %s (re-notification after cool-down)\n' "$firing"
    fi
    if [ -n "$top" ]; then
        printf '\n%s\n' "$top"
    fi
}

_terminal_block() {
    local sev=$1 metric=$2 body=$3
    if [ "${TERMINAL_OUTPUT:-false}" != true ]; then return 0; fi
    printf '\n%s======== %s: %s @ %s ========%s\n' \
        "$(log_color "$sev")" "$sev" "$metric" "$HOST_LABEL" "$(log_reset)"
    printf '%s\n' "$body"
    printf '%s==========================================%s\n\n' "$(log_color "$sev")" "$(log_reset)"
}

# ---------------------------------------------------------------------------
# Channels
# ---------------------------------------------------------------------------
notify_webhook() {
    local sev=$1 subject=$2 body=$3
    local type icon bold fence text payload err

    type=${WEBHOOK_TYPE,,}
    case "$sev" in
        CRITICAL)  icon="🚨" ;;
        WARN)      icon="⚠️" ;;
        RECOVERED) icon="✅" ;;
        *)         icon="ℹ️" ;;
    esac

    if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] would POST ${type} webhook: ${subject}"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is not installed; cannot send webhook"
        return 1
    fi

    fence='```'
    bold='*'
    if [ "$type" = discord ]; then bold='**'; fi
    # Chat platforms cap message size (Discord: 2000 chars) -> truncate the body.
    text="${icon} ${bold}${subject}${bold}"$'\n'"${fence}"$'\n'"${body:0:1500}"$'\n'"${fence}"

    case "$type" in
        slack)
            payload="{\"text\":\"$(json_escape "$text")\"}" ;;
        discord)
            payload="{\"username\":\"server-monitor\",\"content\":\"$(json_escape "$text")\"}" ;;
        generic)
            payload="{\"severity\":\"${sev}\",\"host\":\"$(json_escape "$HOST_LABEL")\",\"subject\":\"$(json_escape "$subject")\",\"message\":\"$(json_escape "$body")\"}" ;;
        *)
            log_error "Unknown WEBHOOK_TYPE '${WEBHOOK_TYPE}' (use slack, discord or generic)"
            return 1 ;;
    esac

    if err=$(curl -fsS -o /dev/null -m "${WEBHOOK_TIMEOUT:-10}" --retry 2 --retry-delay 2 \
        -X POST -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" 2>&1); then
        log_info "Webhook delivered (${type})"
        return 0
    fi
    log_error "Webhook delivery failed: ${err:-unknown error}"
    return 1
}

notify_mail() {
    local sev=$1 subject=$2 body=$3
    local -a rcpts

    if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] would mail ${MAIL_TO}: ${subject}"
        return 0
    fi
    if ! command -v mail >/dev/null 2>&1; then
        log_error "'mail' command not found; cannot send e-mail alert"
        return 1
    fi
    read -ra rcpts <<< "$MAIL_TO"
    if printf '%s\n' "$body" | mail -s "$subject" "${rcpts[@]}"; then
        log_info "Mail delivered to ${MAIL_TO}"
        return 0
    fi
    log_error "Mail delivery to ${MAIL_TO} failed"
    return 1
}

notify_syslog() {
    local sev=$1 subject=$2 prio
    case "$sev" in
        CRITICAL) prio="daemon.crit" ;;
        WARN)     prio="daemon.warning" ;;
        *)        prio="daemon.info" ;;
    esac
    if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] would write to syslog (${prio}): ${subject}"
        return 0
    fi
    if ! command -v logger >/dev/null 2>&1; then
        return 1
    fi
    logger -t server-monitor -p "$prio" -- "$subject"
}

# alert_dispatch <sev> <subject> <body>
# Returns 0 when delivered, or when no external channel is configured (the log
# file and syslog still record it). Returns 1 when external channels are
# configured but every one of them failed - the caller then skips the cool-down
# state so the alert is retried on the next run.
alert_dispatch() {
    local sev=$1 subject=$2 body=$3
    local external=false delivered=false

    if [ -n "${WEBHOOK_URL:-}" ]; then
        external=true
        if notify_webhook "$sev" "$subject" "$body"; then delivered=true; fi
    fi
    if [ "$delivered" = false ] && [ -n "${MAIL_TO:-}" ]; then
        external=true
        if notify_mail "$sev" "$subject" "$body"; then delivered=true; fi
    fi
    if [ "${USE_SYSLOG:-false}" = true ]; then
        notify_syslog "$sev" "$subject" || true
    fi

    if [ "$external" = false ]; then
        if [ "${USE_SYSLOG:-false}" = true ]; then
            log_info "No webhook/mail channel configured; alert kept in log file and syslog"
        else
            log_info "No webhook/mail channel configured; alert kept in log file only"
        fi
        return 0
    fi
    [ "$delivered" = true ]
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
# alert_raise <WARN|CRITICAL> <key> <metric> <value> <threshold> <message>
alert_raise() {
    local sev=$1 key=$2 metric=$3 value=$4 threshold=$5 message=$6
    local now first firing="" top body subject

    now=$(date +%s)
    case "$sev" in
        CRITICAL) ALERTS_CRIT=$((ALERTS_CRIT + 1)) ;;
        *)        ALERTS_WARN=$((ALERTS_WARN + 1)) ;;
    esac

    if alert_is_throttled "$key" "$sev"; then
        log_event "$sev" "$metric" "$value" "$threshold" \
            "${message} [notification suppressed: ${ALERT_COOLDOWN_MINUTES}m cool-down active]"
        return 0
    fi

    log_event "$sev" "$metric" "$value" "$threshold" "$message"

    first=$now
    if _state_read "$key"; then
        first=$ST_FIRST
        firing=$(_fmt_duration $((now - first)))
    fi

    top=$(metric_top_processes)
    subject="[${sev}] ${HOST_LABEL}: ${message}"
    body=$(_build_body "$sev" "$metric" "$value" "$threshold" "$message" "$firing" "$top")
    _terminal_block "$sev" "$metric" "$body"

    if alert_dispatch "$sev" "$subject" "$body"; then
        if [ "$DRY_RUN" != true ]; then
            _state_write "$key" "$sev" "$first"
        fi
    else
        log_error "All notification channels failed for '${key}'; will retry on next run"
    fi
    return 0
}

# alert_clear <key> <metric> <message>: send RECOVERED if the key was alerting.
alert_clear() {
    local key=$1 metric=$2 message=$3
    local now dur subject body prev_sev

    _state_read "$key" || return 0
    prev_sev=$ST_SEV
    now=$(date +%s)
    dur=$(_fmt_duration $((now - ST_FIRST)))

    log_event INFO "$metric" ok - "RECOVERED: ${message} (was ${prev_sev} for ${dur})"

    subject="[RECOVERED] ${HOST_LABEL}: ${message}"
    body=$(_build_body "RECOVERED" "$metric" "ok" "-" "${message} (was ${prev_sev} for ${dur})" "" "")
    _terminal_block "RECOVERED" "$metric" "$body"

    alert_dispatch "RECOVERED" "$subject" "$body" || log_warn "Recovery notice for '${key}' could not be delivered"
    if [ "$DRY_RUN" != true ]; then
        rm -f "$(_state_file "$key")"
    fi
    return 0
}

# alert_send_test: push a synthetic CRITICAL alert through every channel,
# bypassing throttling and without touching state.
alert_send_test() {
    local top body subject
    top=$(metric_top_processes)
    subject="[TEST] ${HOST_LABEL}: server-monitor test alert"
    body=$(_build_body "CRITICAL" "test_alert" "100%" "80%" \
        "Synthetic test alert generated with --test-alert" "" "$top")

    log_event INFO test_alert 100% 80% "Manual test alert requested"
    _terminal_block "CRITICAL" "test_alert" "$body"

    if alert_dispatch "CRITICAL" "$subject" "$body"; then
        log_info "Test alert dispatched"
        return 0
    fi
    log_error "Test alert could not be delivered on any configured channel"
    return 1
}
