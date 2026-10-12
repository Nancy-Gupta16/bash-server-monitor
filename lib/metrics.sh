#!/usr/bin/env bash
# =============================================================================
# lib/metrics.sh - Functions that gather individual system metrics
#
# Every metric_* function prints its result on stdout and returns 0. They never
# alert or log; interpretation (thresholds) lives in monitor.sh.
#
# Output formats:
#   metric_cpu_usage        -> "37.4"                       (percent)
#   metric_memory           -> "62.1 4890 2987 7877"        (pct used_MB free_MB total_MB)
#   metric_disk_usage       -> "<pct>\t<mount>" per line
#   metric_service_status   -> active|inactive|failed|activating|not-found|...
#   metric_default_gateway  -> "192.168.1.1" (empty if none)
#   metric_ping <target>    -> "<loss_pct> <avg_rtt_ms>"    ("unavailable -" if no ping)
#   metric_top_processes    -> human readable text block
# =============================================================================

if [ -n "${_METRICS_SH_LOADED:-}" ]; then return 0; fi
_METRICS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Numeric helpers
# ---------------------------------------------------------------------------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# float_gt A B -> success when A > B (uses bc when present, awk otherwise)
float_gt() {
    is_number "${1:-}" && is_number "${2:-}" || return 1
    if command -v bc >/dev/null 2>&1; then
        [ "$(printf '%s > %s\n' "$1" "$2" | bc -l)" = "1" ]
    else
        awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
    fi
}

# float_ge A B -> success when A >= B
float_ge() {
    is_number "${1:-}" && is_number "${2:-}" || return 1
    ! float_gt "$2" "$1"
}

_with_timeout() {
    local secs=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# CPU: overall utilisation measured from two /proc/stat samples.
# ---------------------------------------------------------------------------
metric_cpu_usage() {
    local sample="${CPU_SAMPLE_SECONDS:-2}"
    local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
    local idle1 idle2 total1 total2 dt di

    read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
    sleep "$sample"
    read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat

    idle1=$((i1 + w1))
    idle2=$((i2 + w2))
    total1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1))
    total2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2))
    dt=$((total2 - total1))
    di=$((idle2 - idle1))

    if [ "$dt" -le 0 ]; then
        echo "0.0"
    else
        awk -v dt="$dt" -v di="$di" 'BEGIN { printf "%.1f\n", (dt - di) * 100 / dt }'
    fi
}

metric_load_average() {
    cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "n/a"
}

# ---------------------------------------------------------------------------
# Memory: "used" = total - MemAvailable (kernel's estimate of reclaimable RAM).
# ---------------------------------------------------------------------------
metric_memory() {
    awk '
        /^MemTotal:/     { t = $2 }
        /^MemAvailable:/ { a = $2; have_a = 1 }
        /^MemFree:/      { f = $2 }
        /^Buffers:/      { b = $2 }
        /^Cached:/       { c = $2 }
        END {
            if (!have_a) a = f + b + c
            u = t - a
            printf "%.1f %d %d %d\n", (t > 0 ? u * 100 / t : 0), u / 1024, a / 1024, t / 1024
        }' /proc/meminfo
}

# ---------------------------------------------------------------------------
# Disk: with no arguments, auto-discovers real filesystems; with arguments,
# reports the filesystem holding each given path.
# ---------------------------------------------------------------------------
metric_disk_usage() {
    local -a args=()
    local fs
    if [ "$#" -eq 0 ]; then
        for fs in ${DISK_EXCLUDE_FS:-}; do
            args+=(-x "$fs")
        done
    fi

    _with_timeout 15 df -P ${args[@]+"${args[@]}"} "$@" 2>/dev/null | awk '
        NR == 1 { next }
        {
            pct = $5; sub(/%/, "", pct)
            mp = $6
            for (i = 7; i <= NF; i++) mp = mp " " $i
            if (pct ~ /^[0-9]+$/ && !(mp in seen)) {
                seen[mp] = 1
                printf "%s\t%s\n", pct, mp
            }
        }' || true
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
_service_aliases() {
    case "$1" in
        sshd)    echo "ssh" ;;
        ssh)     echo "sshd" ;;
        cron)    echo "crond" ;;
        crond)   echo "cron" ;;
        apache2) echo "httpd" ;;
        httpd)   echo "apache2" ;;
        mysql)   echo "mysqld mariadb" ;;
        mysqld)  echo "mysql mariadb" ;;
        mariadb) echo "mysql mysqld" ;;
        *) ;;
    esac
}

_unit_exists() {
    local load
    load=$(systemctl show -p LoadState "$1.service" 2>/dev/null | sed 's/^LoadState=//' || true)
    [ -n "$load" ] && [ "$load" != "not-found" ]
}

# Prints the first existing unit among the name and its aliases (empty if none).
_resolve_unit() {
    local svc="${1%.service}" cand
    for cand in "$svc" $(_service_aliases "$svc"); do
        if _unit_exists "$cand"; then
            echo "$cand"
            return 0
        fi
    done
    return 0
}

metric_service_status() {
    local svc="$1" unit state

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        unit=$(_resolve_unit "$svc")
        if [ -z "$unit" ]; then
            echo "not-found"
            return 0
        fi
        state=$(systemctl is-active "$unit.service" 2>/dev/null || true)
        state=${state%%$'\n'*}
        # Socket-activated daemons (e.g. ssh.socket) are healthy while their
        # service is idle.
        if [ "$state" = "inactive" ] && [ "$(systemctl is-active "$unit.socket" 2>/dev/null || true)" = "active" ]; then
            state="active"
        fi
        echo "${state:-unknown}"
    else
        # No systemd (containers, minimal hosts): fall back to a process lookup.
        if pgrep -x "$svc" >/dev/null 2>&1; then
            echo "active"
        else
            echo "inactive"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
metric_default_gateway() {
    ip route show default 2>/dev/null | awk '/^default/ { print $3; exit }' || true
}

metric_ping() {
    local target="$1" count="${PING_COUNT:-3}" wait="${PING_TIMEOUT:-3}"
    local out loss rtt

    if ! command -v ping >/dev/null 2>&1; then
        echo "unavailable -"
        return 0
    fi

    out=$(ping -c "$count" -W "$wait" -q "$target" 2>&1 || true)
    loss=$(printf '%s\n' "$out" | sed -n 's/.*[ ,]\([0-9.]*\)% packet loss.*/\1/p' | head -n1 || true)
    rtt=$(printf '%s\n' "$out" | awk -F'/' '/^(rtt|round-trip)/ { print $5; exit }' || true)

    if [ -z "$loss" ]; then loss=100; fi
    if [ -z "$rtt" ]; then rtt="-"; fi
    echo "$loss $rtt"
}

# ---------------------------------------------------------------------------
# Top resource consumers (attached to every alert)
# ---------------------------------------------------------------------------
metric_top_processes() {
    local n="${TOP_N:-5}"

    printf 'Load average (1/5/15m): %s\n\n' "$(metric_load_average)"
    printf 'Top %s processes by CPU:\n' "$n"
    ps -eo pid,user:12,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -n $((n + 1)) || true
    printf '\nTop %s processes by memory:\n' "$n"
    ps -eo pid,user:12,pcpu,pmem,comm --sort=-pmem 2>/dev/null | head -n $((n + 1)) || true
}
