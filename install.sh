#!/usr/bin/env bash
# =============================================================================
# install.sh - Verify dependencies, set permissions and register the cron job
#
# Usage: ./install.sh [--skip-cron] [--uninstall] [-h|--help]
#
# Environment:
#   CRON_SCHEDULE   cron expression (default: "*/5 * * * *" = every 5 minutes)
#
# The cron job is installed in the crontab of the user running this script.
# Run as root (or via sudo) to monitor system services without permission
# issues; run as a normal user for a least-privilege setup.
# =============================================================================
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(dirname "$SCRIPT_PATH")"
CONF="${BASE_DIR}/config/monitor.conf"
CRON_TAG="# server-monitor"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
SKIP_CRON=false
UNINSTALL=false

c_ok()   { printf '  [ OK ] %s\n' "$*"; }
c_warn() { printf '  [WARN] %s\n' "$*"; }
c_fail() { printf '  [FAIL] %s\n' "$*"; }
step()   { printf '\n==> %s\n' "$*"; }

usage() {
    sed -n '3,12p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --skip-cron) SKIP_CRON=true ;;
        --uninstall) UNINSTALL=true ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

# --- package manager detection and package-name mapping ----------------------
detect_pkg_manager() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk; do
        if command -v "$pm" >/dev/null 2>&1; then echo "$pm"; return 0; fi
    done
    echo "unknown"
}

pkg_for() {
    local cmd=$1 pm=$2
    case "$cmd" in
        mail)
            case "$pm" in
                apt-get) echo "mailutils" ;;
                dnf|yum) echo "s-nail" ;;
                *)       echo "mailx" ;;
            esac ;;
        ping)
            case "$pm" in
                apt-get) echo "iputils-ping" ;;
                *)       echo "iputils" ;;
            esac ;;
        ip)
            case "$pm" in
                apt-get) echo "iproute2" ;;
                *)       echo "iproute" ;;
            esac ;;
        systemctl) echo "systemd" ;;
        flock|logger) echo "util-linux" ;;
        ps|pgrep) echo "procps" ;;
        crontab)
            case "$pm" in
                apt-get) echo "cron" ;;
                *)       echo "cronie" ;;
            esac ;;
        awk) echo "gawk" ;;
        *)   echo "$cmd" ;;
    esac
}

install_hint() {
    local pm pkgs=() cmd
    pm=$(detect_pkg_manager)
    for cmd in "$@"; do pkgs+=("$(pkg_for "$cmd" "$pm")"); done
    case "$pm" in
        apt-get) echo "sudo apt-get install -y ${pkgs[*]}" ;;
        dnf)     echo "sudo dnf install -y ${pkgs[*]}" ;;
        yum)     echo "sudo yum install -y ${pkgs[*]}" ;;
        zypper)  echo "sudo zypper install -y ${pkgs[*]}" ;;
        pacman)  echo "sudo pacman -S --needed ${pkgs[*]}" ;;
        apk)     echo "sudo apk add ${pkgs[*]}" ;;
        *)       echo "install the packages providing: $*" ;;
    esac
}

# --- steps -------------------------------------------------------------------
check_dependencies() {
    local cmd missing_req=() missing_opt=()
    # Required: monitoring cannot work without these.
    local -a required=(awk sed grep df ps find date stat readlink)
    # Recommended: each enables a specific feature.
    local -a optional=(curl mail systemctl bc ping ip flock logger crontab timeout gzip)

    step "Checking dependencies"
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        c_fail "Bash 4+ required (found ${BASH_VERSION})"
        exit 1
    fi
    c_ok "bash ${BASH_VERSION}"

    for cmd in "${required[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then c_ok "$cmd"; else c_fail "$cmd (required)"; missing_req+=("$cmd"); fi
    done

    for cmd in "${optional[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            c_ok "$cmd"
        else
            missing_opt+=("$cmd")
            case "$cmd" in
                curl)      c_warn "curl missing: Slack/Discord webhooks disabled" ;;
                mail)      c_warn "mail missing: e-mail fallback disabled" ;;
                systemctl) c_warn "systemctl missing: service checks fall back to pgrep" ;;
                bc)        c_warn "bc missing: threshold maths falls back to awk (fine)" ;;
                ping)      c_warn "ping missing: network checks will be skipped" ;;
                crontab)   c_warn "crontab missing: cannot register the scheduled job" ;;
                *)         c_warn "$cmd missing (optional)" ;;
            esac
        fi
    done

    if [ ${#missing_req[@]} -gt 0 ]; then
        echo
        echo "Install the required tools, then re-run:"
        echo "  $(install_hint "${missing_req[@]}")"
        exit 1
    fi
    if [ ${#missing_opt[@]} -gt 0 ]; then
        echo
        echo "  To enable every feature:  $(install_hint "${missing_opt[@]}")"
    fi
}

# Read LOG_FILE / STATE_DIR from the config in a subshell (no side effects).
conf_value() {
    local var=$1
    ( set +u; BASE_DIR="$BASE_DIR"; . "$CONF"; printf '%s' "${!var:-}" )
}

setup_permissions() {
    local log_file state_dir log_dir
    step "Configuring permissions and directories"

    chmod 700 "${BASE_DIR}/monitor.sh" "${BASE_DIR}/install.sh"
    chmod 600 "$CONF"
    chmod 640 "${BASE_DIR}"/lib/*.sh
    c_ok "scripts executable by owner only; config/monitor.conf set to 600 (may hold a webhook secret)"

    log_file=$(conf_value LOG_FILE)
    state_dir=$(conf_value STATE_DIR)
    log_file="${log_file:-${BASE_DIR}/logs/monitor.log}"
    state_dir="${state_dir:-${BASE_DIR}/state}"
    log_dir=$(dirname "$log_file")

    mkdir -p "$log_dir" "$state_dir"
    chmod 750 "$log_dir" "$state_dir"
    c_ok "log directory:   $log_dir"
    c_ok "state directory: $state_dir"
    LOG_DIR_RESOLVED="$log_dir"
}

syntax_check() {
    local f
    step "Syntax-checking scripts"
    for f in "${BASE_DIR}/monitor.sh" "${BASE_DIR}/install.sh" "${BASE_DIR}"/lib/*.sh; do
        if bash -n "$f"; then c_ok "${f#"${BASE_DIR}"/}"; else c_fail "$f"; exit 1; fi
    done
}

current_crontab() {
    crontab -l 2>/dev/null || true
}

register_cron() {
    local line existing
    step "Registering cron job (${CRON_SCHEDULE})"

    if [ "$SKIP_CRON" = true ]; then c_warn "skipped (--skip-cron)"; return 0; fi
    if ! command -v crontab >/dev/null 2>&1; then
        c_warn "crontab not available; add this line manually:"
        echo "      ${CRON_SCHEDULE} ${BASE_DIR}/monitor.sh >> ${LOG_DIR_RESOLVED}/cron.log 2>&1 ${CRON_TAG}"
        return 0
    fi

    line="${CRON_SCHEDULE} \"${BASE_DIR}/monitor.sh\" >> \"${LOG_DIR_RESOLVED}/cron.log\" 2>&1 ${CRON_TAG}"
    existing=$(current_crontab | grep -vF "$CRON_TAG" || true)
    { [ -n "$existing" ] && printf '%s\n' "$existing"; printf '%s\n' "$line"; } | crontab -
    c_ok "installed for user $(id -un):"
    echo "      $line"
}

remove_cron() {
    local existing
    step "Removing cron job"
    if ! command -v crontab >/dev/null 2>&1; then c_warn "crontab not available"; return 0; fi
    existing=$(current_crontab | grep -vF "$CRON_TAG" || true)
    if [ -n "$existing" ]; then
        printf '%s\n' "$existing" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
    c_ok "cron entry removed (logs and state were left in place)"
}

smoke_test() {
    step "Smoke test (dry run - sends nothing)"
    set +e
    "${BASE_DIR}/monitor.sh" --dry-run >/dev/null 2>&1
    local rc=$?
    set -e
    case "$rc" in
        0) c_ok "dry run completed: all checks healthy" ;;
        1|2) c_ok "dry run completed: checks found issues on this host (exit $rc) - see './monitor.sh --check-now'" ;;
        *) c_fail "dry run failed (exit $rc) - run './monitor.sh --dry-run' to see why"; exit 1 ;;
    esac
}

next_steps() {
    cat <<EOF

Installation complete.

Next steps:
  1. Edit ${CONF}
       - set CRITICAL_SERVICES to the daemons that matter on this host
       - set WEBHOOK_URL (Slack/Discord) and/or MAIL_TO
  2. Verify end-to-end delivery:   ${BASE_DIR}/monitor.sh --test-alert
  3. Run a live check:             ${BASE_DIR}/monitor.sh --check-now
  4. Watch the log:                tail -f ${LOG_DIR_RESOLVED}/monitor.log
  5. Uninstall the schedule:       ${BASE_DIR}/install.sh --uninstall
EOF
}

# --- main --------------------------------------------------------------------
LOG_DIR_RESOLVED="${BASE_DIR}/logs"

if [ "$UNINSTALL" = true ]; then
    remove_cron
    exit 0
fi

echo "server-monitor installer (${BASE_DIR})"
check_dependencies
setup_permissions
syntax_check
register_cron
smoke_test
next_steps
