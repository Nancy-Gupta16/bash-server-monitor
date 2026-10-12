# server-monitor

A production-style Linux server monitoring and alerting system written in modular Bash. It checks CPU, memory, disk, critical services and network reachability, captures the top resource consumers when something breaks, de-duplicates noisy alerts, and delivers notifications to a structured log, the terminal, Slack/Discord (webhook), local mail and syslog.

Runs from cron every 5 minutes. No daemons, no databases, no dependencies beyond standard Linux tooling.

---

## 1. Architecture and folder layout

```
server-monitor/
├── monitor.sh            # Entry point: argument parsing, orchestration, traps, exit codes
├── install.sh            # Dependency check, permissions, cron registration, smoke test
├── config/
│   └── monitor.conf      # Thresholds, services, webhook/mail, paths (sourced as Bash)
├── lib/
│   ├── logger.sh         # Structured logging, daily rotation, 7-day cleanup
│   ├── metrics.sh        # One function per metric (CPU, memory, disk, service, ping, top)
│   └── alerts.sh         # Alert formatting, cool-down/throttling, recovery, channels
├── logs/                 # Created at install: monitor.log, rotated logs, cron.log
└── state/                # Created at install: per-alert throttle state + run lock
```

### Data flow

```
cron (*/5) ─► monitor.sh ─► load_config ─► lock (flock) ─► log_cleanup
                              │
                              ▼
            check_cpu / memory / disks / services / network
                  │  (lib/metrics.sh gathers raw values)
                  ▼
        evaluate vs thresholds ──ok──► INFO log ─► alert_clear (RECOVERED if it was firing)
                  │ breach
                  ▼
        alert_raise (lib/alerts.sh)
          ├─ throttled? ─yes─► log "suppressed", stop
          └─ no ─► snapshot top 5 CPU/RAM ─► build body
                    ├─► log file          (always)
                    ├─► terminal block    (tty / --check-now)
                    ├─► webhook           (Slack / Discord / generic)
                    ├─► mail fallback     (if no webhook or webhook failed)
                    └─► syslog            (if USE_SYSLOG=true)
```

### Design decisions

| Concern | Approach |
|---|---|
| Strict mode | `set -Eeuo pipefail`, an `ERR` trap that logs the failing line, `INT/TERM/HUP` traps, and an `EXIT` trap that logs the run summary |
| Isolation | Each check runs through `run_check`, so one failing check never stops the others |
| Overlap protection | `flock` on `state/monitor.lock`; a slow run cannot be stacked by the next cron tick |
| Throttling | Per-alert state file: `<last_epoch> <severity> <first_seen_epoch> <key>`. Same or lower severity inside the cool-down is suppressed; WARN to CRITICAL escalation always notifies |
| Delivery safety | If every configured external channel fails, no cool-down state is written, so the alert is retried on the next run instead of being silently lost |
| Recovery | When a metric returns to normal, a `RECOVERED` notice is sent and the state is cleared |
| Secrets | Config is refused if world-writable; installer sets it to `600`; webhook URL is never written to logs |
| Memory accounting | Uses `MemAvailable` (not `MemFree`), so page cache is not reported as "used" |
| Portability | Aliases (`sshd`/`ssh`, `cron`/`crond`, `apache2`/`httpd`), socket-activated daemon handling, `pgrep` fallback without systemd, `awk` fallback without `bc` |

---

## 2. Installation and deployment

### Prerequisites

Linux with Bash 4+, `awk`, `sed`, `df`, `ps`, `find`. Recommended: `curl` (webhooks), `mail` (fallback), `systemctl`, `bc`, `ping`, `ip`, `flock`, `logger`, `cron`.

```bash
# Debian / Ubuntu
sudo apt-get install -y curl mailutils bc iputils-ping iproute2 cron util-linux procps
# RHEL / Rocky / Alma / Fedora
sudo dnf install -y curl s-nail bc iputils iproute cronie util-linux procps-ng
```

### Step by step

```bash
# 1. Place the project somewhere stable
sudo mkdir -p /opt/server-monitor
sudo cp -r server-monitor/. /opt/server-monitor/
cd /opt/server-monitor

# 2. Run the installer (checks dependencies, sets permissions, registers cron)
sudo bash install.sh

# 3. Configure what matters on THIS host
sudo nano config/monitor.conf
#    CRITICAL_SERVICES="sshd cron nginx docker"
#    WEBHOOK_URL="https://hooks.slack.com/services/..."   (or a Discord webhook)
#    WEBHOOK_TYPE="slack"                                 (slack | discord | generic)
#    MAIL_TO="oncall@example.com"

# 4. Prove the delivery path works end to end
sudo ./monitor.sh --test-alert

# 5. Run one live check
sudo ./monitor.sh --check-now
```

`install.sh` is idempotent: running it again replaces its own cron line (tagged `# server-monitor`) and leaves other cron jobs untouched. Useful variants:

```bash
sudo bash install.sh --skip-cron             # everything except the cron job
CRON_SCHEDULE="*/2 * * * *" sudo -E bash install.sh   # custom interval
sudo bash install.sh --uninstall             # remove the cron job (logs are kept)
```

The resulting crontab entry:

```
*/5 * * * * "/opt/server-monitor/monitor.sh" >> "/opt/server-monitor/logs/cron.log" 2>&1 # server-monitor
```

### Running as root vs. a normal user

Root can inspect every service and partition. A dedicated unprivileged user also works, since `systemctl is-active`, `df`, `ps` and `ping` need no privileges on most distributions. Mail and syslog delivery work for either.

### Using `/var/log` instead of the project folder

In `config/monitor.conf`:

```bash
LOG_FILE="/var/log/server_monitor.log"
```

Make sure the running user can write to `/var/log` (or pre-create the file and `chown` it).

---

## 3. Command reference

| Command | Purpose |
|---|---|
| `./monitor.sh` | Quiet run (what cron executes) |
| `./monitor.sh --check-now` | Run immediately with live, coloured terminal output |
| `./monitor.sh --dry-run` | Evaluate everything and print what would be sent. Sends nothing, writes no log, no state |
| `./monitor.sh --test-alert` | Push a synthetic CRITICAL alert through every configured channel |
| `./monitor.sh --status` | List alerts currently being throttled (active incidents) |
| `./monitor.sh --cleanup` | Rotate the log and delete rotated logs older than `LOG_RETENTION_DAYS` |
| `./monitor.sh --config FILE` | Use an alternative config (handy for tests) |

Exit codes: `0` healthy, `1` warnings, `2` critical, `3` usage/config error. This makes the script usable from other tooling, not just cron.

### Log format

One event per line, ISO-8601 timestamp with offset, pipe-delimited `key=value` fields:

```
2026-10-11T09:34:26+00:00 | WARN     | host=vm | metric=cpu_usage | value=0.5% | threshold=0% | message="CPU usage is 0.5% (warning > 0%)"
2026-10-11T09:34:26+00:00 | CRITICAL | host=vm | metric=service_nginx | value=inactive | threshold=active | message="Service nginx is inactive"
2026-10-11T09:34:32+00:00 | WARN     | host=vm | metric=cpu_usage | value=0.5% | threshold=0% | message="CPU usage is 0.5% (warning > 0%) [notification suppressed: 15m cool-down active]"
2026-10-11T09:34:40+00:00 | INFO     | host=vm | metric=cpu_usage | value=ok | threshold=- | message="RECOVERED: CPU usage is back to normal (1.0%) (was WARN for 14s)"
```

Severities are `INFO`, `WARN`, `CRITICAL`, plus `ERROR` for failures of the tool itself (for example a webhook that returned HTTP 404). Handy queries:

```bash
grep -E '\| (WARN|CRITICAL) ' logs/monitor.log | tail -20          # recent problems
grep 'metric=disk_usage' logs/monitor.log | tail -5                 # one metric's history
grep -c 'suppressed' logs/monitor.log                               # how much noise was throttled
grep '| ERROR ' logs/monitor.log                                    # is the tool itself healthy?
zcat logs/monitor.log.*.gz | grep CRITICAL                          # yesterday and earlier
```

### Rotation and retention

On every run (and with `--cleanup`) the log is rotated if it was last written on an earlier day: the old entries move to `monitor.log.YYYY-MM-DD.gz`. Rotated files older than `LOG_RETENTION_DAYS` (default 7) are deleted, stale throttle-state files are pruned, and `cron.log` is capped at about 1 MB.

---

## 4. Manual verification and simulated incidents

Always begin with the safe commands:

```bash
./monitor.sh --dry-run          # nothing is sent or written
./monitor.sh --check-now        # real run with terminal output
./monitor.sh --test-alert       # proves webhook / mail / syslog delivery
```

Use a throwaway config for simulations so production thresholds stay untouched:

```bash
cp config/monitor.conf /tmp/sim.conf && chmod 600 /tmp/sim.conf
# edit /tmp/sim.conf, then:  ./monitor.sh --config /tmp/sim.conf --check-now
```
(`${BASE_DIR}` in the copied config still resolves to the project directory.)

### 4.1 CPU

```bash
# Generate load on every core for 3 minutes (either tool works)
stress-ng --cpu 0 --timeout 180s &
# or, with no extra packages:
for i in $(seq "$(nproc)"); do (timeout 180 sh -c 'while :; do :; done' &) ; done

./monitor.sh --check-now        # expect: WARN/CRITICAL cpu_usage + top-5 CPU table
```

### 4.2 Memory

```bash
stress-ng --vm 1 --vm-bytes 85% --vm-keep --timeout 120s &
./monitor.sh --check-now        # expect: memory_usage alert, culprit at top of the RAM table
```
Use a VM or test host. Pushing a production box to 85% memory is not harmless.

### 4.3 Disk partition

```bash
# Build a small 200 MB filesystem and fill it to ~90%
dd if=/dev/zero of=/tmp/small.img bs=1M count=200
mkfs.ext4 -q -F /tmp/small.img
sudo mkdir -p /mnt/small && sudo mount -o loop /tmp/small.img /mnt/small
sudo fallocate -l 165M /mnt/small/fill.bin

./monitor.sh --check-now        # expect: WARN disk_usage:/mnt/small

# cleanup
sudo rm /mnt/small/fill.bin   # next run sends RECOVERED
sudo umount /mnt/small && rm /tmp/small.img
```

### 4.4 Service down (real and fake)

```bash
# Fake service: not installed at all -> WARN "not found" (flags a config mistake)
#   in /tmp/sim.conf:  CRITICAL_SERVICES="sshd cron does-not-exist"

# Real outage: stop a harmless service you listed in CRITICAL_SERVICES
sudo systemctl stop cron
./monitor.sh --check-now        # expect: CRITICAL service_cron
sudo systemctl start cron
./monitor.sh --check-now        # expect: RECOVERED service_cron
```

### 4.5 Network

```bash
# 192.0.2.0/24 (TEST-NET-1) is reserved and never routable
#   in /tmp/sim.conf:  PING_TARGETS="192.0.2.1"
./monitor.sh --config /tmp/sim.conf --check-now      # expect: CRITICAL ping_loss, 100% loss
```

### 4.6 Throttling and de-duplication

```bash
./monitor.sh --config /tmp/sim.conf        # first run: alert delivered
./monitor.sh --config /tmp/sim.conf        # second run: log says "notification suppressed: 15m cool-down active"
./monitor.sh --status                      # shows the alert, how long it has been firing, last notification time
rm state/alert_*.state                     # force the cool-down to reset (test only)
```

Escalation is never throttled. A key that moves from WARN to CRITICAL notifies immediately.

### 4.7 Webhook without a real Slack/Discord

```bash
# Terminal 1: tiny local receiver
python3 -m http.server 8099      # any listener will do; a 501 reply still shows the request

# Terminal 2: in /tmp/sim.conf set WEBHOOK_URL="http://127.0.0.1:8099/hook"
./monitor.sh --config /tmp/sim.conf --test-alert
```
A refused or failed delivery is logged as `ERROR` and the alert is retried on the next run (no cool-down is recorded).

---

## 5. Incident runbook: a CRITICAL alert has fired

Goal for the first five minutes: **confirm it is real, find the blast radius, stop the bleeding, tell people.**

### Step 0: Acknowledge and read the alert

The alert body already contains the host, time, metric, value vs. threshold and a snapshot of the top 5 processes by CPU and memory taken at alert time. Read that first; it often names the culprit.

```bash
ssh <host>
cd /opt/server-monitor
./monitor.sh --status                          # everything currently firing and for how long
grep -E '\| (WARN|CRITICAL) ' logs/monitor.log | tail -30   # when did it start, did it flap?
uptime; who                                    # load trend, who else is on the box
```

### Step 1: Confirm and classify

Re-measure by hand. Do not trust one sample, and do not assume the monitor is wrong either.

| Alert metric | Confirm with |
|---|---|
| `cpu_usage` | `top -o %CPU`, `uptime` (load vs. `nproc`), `pidstat 1 5` |
| `memory_usage` | `free -m`, `ps aux --sort=-rss \| head`, `dmesg -T \| grep -i 'out of memory'`, `journalctl -k -g oom` |
| `disk_usage:<mount>` | `df -hT`, `df -i` (inodes!), `sudo du -xh <mount> --max-depth=2 \| sort -h \| tail -15` |
| `service_<name>` | `systemctl status <name>`, `journalctl -u <name> -n 100 --no-pager` |
| `ping_loss` / `network_gateway` | `ip addr; ip route`, `ping -c3 <gateway>`, `ping -c3 1.1.1.1`, `dig example.com` |

### Step 2: Triage by type

**CPU**
1. Is it one process or many? A single runaway process: inspect it (`ls -l /proc/<pid>/exe`, `strace -p <pid> -c`, its logs).
2. Is it expected (batch job, backup, deploy)? Check cron and recent deploys: `grep CRON /var/log/syslog | tail`.
3. Many processes on a web host: check for a traffic spike or attack (`ss -s`, `tail -f` the access log, `fail2ban-client status`).
4. Mitigate: `renice +10 <pid>`, then graceful `kill <pid>`, then restart the service. Use `kill -9` only as a last resort.

**Memory**
1. Find the top RSS consumers and check for an OOM kill in the kernel log.
2. A leaking service: restart it to restore capacity, and capture evidence first if you can (`pmap -x <pid>`, heap dump).
3. Check swap thrash: `vmstat 1 5` (high `si/so`).
4. Mitigate: restart the offender, drop to fewer workers, or add RAM/swap as a stopgap.

**Disk**
1. Find what grew: `du -xh <mount> --max-depth=2 | sort -h | tail`. Usual suspects: `/var/log`, `/var/lib/docker`, core dumps, `/tmp`, mail spool, old deploy artifacts.
2. Space that does not return after deleting a file means a process still holds it: `sudo lsof +L1 | head`. Restart that process.
3. Safe wins: `sudo journalctl --vacuum-size=200M`, `sudo apt-get clean` (or `dnf clean all`), `docker system df` then `docker image prune`, force rotation with `sudo logrotate -f /etc/logrotate.conf`.
4. Never delete database files or active logs by hand. Truncate (`: > file`) rather than `rm` a live log.

**Service down**
1. `systemctl status <svc>` and `journalctl -u <svc> -n 100` give the reason (crash, config error, port in use, dependency failed).
2. Validate config before restarting: `nginx -t`, `apachectl configtest`, `sshd -t`.
3. Restart: `sudo systemctl restart <svc>`; confirm: `systemctl is-active <svc>` and exercise it (`curl -I localhost`, `ss -ltnp | grep <port>`).
4. If it dies again immediately, stop restarting in a loop and investigate (`systemctl reset-failed <svc>` clears the failed state).
5. If `sshd` itself is down and you are on the console, fix that first; you may be about to lose your only way in.

**Network**
1. Is it this host or the path? Compare gateway vs. external target. Gateway fails: local NIC/link/VLAN (`ip -s link`, `ethtool <if>`). Only the external target fails: upstream or ISP.
2. Check DNS separately from connectivity (`ping 1.1.1.1` works but `dig` fails means resolver problem, see `/etc/resolv.conf`).
3. Check recent firewall or routing changes (`nft list ruleset`, `iptables -S`, `ip route`).
4. Escalate to the network/hosting provider with traceroute evidence: `mtr -rw -c 20 <target>`.

### Step 3: Communicate

Post in the incident channel within 5 minutes, even before you know the cause:

```
[INCIDENT] <host>: <metric> CRITICAL since <time>. Impact: <known/unknown>.
Investigating: <your name>. Next update in 15 min.
```

### Step 4: Resolve and verify

1. Apply the mitigation, then re-measure by hand.
2. Run `./monitor.sh --check-now`. The tool should log `RECOVERED` and send a recovery notice. `./monitor.sh --status` should be empty.
3. Watch for a flap for two cycles (10 minutes). A fix that does not hold is not a fix.

### Step 5: Follow up

Within 48 hours, write a short post-incident note:

- Timeline (first alert time from `logs/monitor.log`, detection, mitigation, recovery)
- Root cause and trigger
- What worked or failed in detection (did the alert fire early enough? was the threshold right?)
- Action items with owners (capacity, log rotation, a missing check, a runbook fix)

If the alert was a false positive or too noisy, **tune it** rather than ignoring it: adjust `*_WARN/*_CRIT` or `ALERT_COOLDOWN_MINUTES` in `config/monitor.conf`. Alert fatigue is an incident waiting to happen.

---

## 6. Troubleshooting the monitor itself

| Symptom | Check |
|---|---|
| No alerts arrive | `./monitor.sh --test-alert`; then `grep '| ERROR ' logs/monitor.log` (webhook HTTP errors, missing `curl`/`mail`) |
| Cron never runs it | `crontab -l \| grep server-monitor`; `grep CRON /var/log/syslog` (Debian) or `journalctl -u crond` (RHEL); read `logs/cron.log` |
| `Config file ... is world-writable` | `chmod 600 config/monitor.conf` |
| Run skipped: "Another instance is still running" | A previous run is hung (usually a stalled `ping` or NFS `df`); `pgrep -af monitor.sh` |
| Alerts keep repeating every 5 min | Check that `state/` is writable by the cron user; throttle state cannot be saved without it |
| Alert is never repeated though still broken | Cool-down active; see `./monitor.sh --status`, or lower `ALERT_COOLDOWN_MINUTES` |
| Service reported "not found" | Wrong unit name; verify with `systemctl list-unit-files '*<name>*'` |
| Wrong partition list | Set `DISK_MOUNTS="/ /var /home"` explicitly, or extend `DISK_EXCLUDE_FS` / `DISK_EXCLUDE_MOUNT_REGEX` |
| Discord returns HTTP 400 | Use `WEBHOOK_TYPE="discord"` (Discord expects `content`, Slack expects `text`) |

---

## 7. Configuration reference

| Variable | Default | Meaning |
|---|---|---|
| `CPU_WARN` / `CPU_CRIT` | 80 / 95 | CPU % thresholds |
| `MEM_WARN` / `MEM_CRIT` | 85 / 95 | Memory % thresholds |
| `DISK_WARN` / `DISK_CRIT` | 85 / 95 | Per-partition % thresholds |
| `CPU_SAMPLE_SECONDS` | 2 | Interval between the two `/proc/stat` samples |
| `DISK_MOUNTS` | empty | Explicit paths to check; empty means auto-discover |
| `DISK_EXCLUDE_FS` | tmpfs devtmpfs squashfs overlay iso9660 efivarfs | Filesystem types ignored in auto-discovery |
| `DISK_EXCLUDE_MOUNT_REGEX` | `^/(snap\|run\|sys\|proc\|dev)(/\|$)` | Mount points ignored in auto-discovery |
| `CRITICAL_SERVICES` | `sshd cron` | Space-separated unit names |
| `PING_TARGETS` | `gateway 1.1.1.1` | Targets; `gateway` resolves the default route |
| `PING_COUNT` / `PING_TIMEOUT` | 3 / 3 | Echo requests per target / seconds per reply |
| `NET_LOSS_WARN` / `NET_LOSS_CRIT` | 25 / 100 | Packet-loss % thresholds |
| `NET_RTT_WARN_MS` | 250 | Average latency that raises WARN |
| `ALERT_COOLDOWN_MINUTES` | 15 | Minimum gap between identical alerts |
| `TOP_N` | 5 | Processes listed per ranking |
| `WEBHOOK_URL` / `WEBHOOK_TYPE` / `WEBHOOK_TIMEOUT` | empty / slack / 10 | Webhook delivery |
| `MAIL_TO` | empty | Fallback recipients (space-separated) |
| `USE_SYSLOG` | true | Also log notifications to syslog (`server-monitor` tag) |
| `HOSTNAME_LABEL` | empty | Display name; empty means `hostname -f` |
| `LOG_FILE` / `STATE_DIR` | `${BASE_DIR}/logs/monitor.log` / `${BASE_DIR}/state` | Paths |
| `LOG_RETENTION_DAYS` | 7 | Age after which rotated logs are deleted |

---

## 8. Security notes

- `config/monitor.conf` is sourced as code. Keep it owned by the monitoring user and mode `600`; `monitor.sh` refuses a world-writable file.
- Webhook URLs are secrets (anyone holding one can post to your channel). They are never written to the log.
- Logs and state are created with `umask 027` (no access for other users).
- The tool is read-only with respect to the system: it never restarts services or deletes anything except its own old logs and state.
