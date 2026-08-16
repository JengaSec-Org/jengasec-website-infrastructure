# `cron`

**Phase 7 · Implemented**

Scheduled maintenance: certificate expiry, disk checks, temporary file cleanup.

## Prefer a systemd timer where one fits

For anything systemd already supervises, a timer beats cron: journal logging,
dependency ordering, `Persistent=true` to catch up after downtime, and
`RandomizedDelaySec` so three servers do not all fire at the same instant. The
[`systemd`](../systemd/README.md) role takes those via `systemd_timers`.

cron is still right for a short, self-contained script on a simple schedule —
which is what all three jobs here are.

## `MAILTO` is the most important line

cron mails the stdout and stderr of any job that produces output. With no
`MAILTO`, that mail goes nowhere and **a job can fail silently for weeks**.

Every script here follows the same convention: **silence means everything is
fine**. They print only when something needs a human.

`PATH` matters for the same class of reason. cron runs with `/usr/bin:/bin`
only, so a script calling `systemctl` or `psql` without a full path works when
tested by hand and fails under cron — a classic afternoon lost.

## The three jobs

| Job | Schedule | Why |
|---|---|---|
| Certificate expiry | 07:00 daily | The internal CA issues one-year certificates and **nothing renews them**. Without this, the first sign of expiry is the site failing. |
| Disk usage | every 6h | The most likely way a small server dies. Mails a human and needs no exporter — useful precisely when monitoring is what broke. |
| Temp cleanup | 03:30 daily | Document parsing leaves files behind on a crashed parse, in the same filesystem as the uploads. |

Prometheus has alerts for the first two, but `CertificateExpiringSoon` needs the
blackbox exporter, which is not deployed. **Today this cron job is the only
thing watching certificate expiry.**

## Scripts, not crontab one-liners

Each job is a real script in `/usr/local/sbin`. A crontab one-liner cannot be
tested by hand, cannot be commented, and quoting inside it is its own hazard.

Two details worth knowing:

**The disk check also looks at inodes.** A filesystem out of inodes reports
plenty of free space while refusing to create a file — a genuinely confusing
failure. When `/` or `/var` is full it also prints the largest directories and
the journal size, so nobody has to go hunting.

**The cleanup is deliberately conservative.** Regular files only, `-atime` not
`-mtime` (a file being *read* still counts as in use), `-xdev` so it never
descends into a mount, and systemd's private directories excluded. An empty
directory costs nothing; removing one a running process expects is far worse
than leaving it.

## Unmanaged entries are reported

Ansible writes each managed job under an `#Ansible: <name>` marker. Anything in
root's crontab without one was added by hand.

The role **reports but does not remove** them — someone may have added one
deliberately. But an unexplained scheduled job is also what persistence looks
like, so it should never go unnoticed. Add legitimate ones to `cron_jobs` so
they survive a rebuild.

## Adding a job

```yaml
cron_jobs:
  - name: "nightly report generation"
    minute: "0"
    hour: "2"
    user: jengasec
    job: "/opt/jengasec/venv/bin/python /opt/jengasec/app/manage.py generate_reports"
```

## Variables

| Variable | Default |
|---|---|
| `cron_mailto` | `sucybersec@strathmore.edu` |
| `cron_path` | full sbin/bin path |
| `cron_cert_check_enabled` | `true` |
| `cron_cert_check_warn_days` | `21` |
| `cron_disk_check_enabled` | `true` |
| `cron_disk_check_threshold` | `os_disk_usage_warn_percent`, 85 |
| `cron_tmp_cleanup_age_days` | `7` |
| `cron_jobs` | `[]` |
| `cron_report_unmanaged` | `true` |

## Tags

`cron`, `directories`, `environment`, `scripts`, `jobs`, `verify`

## Verifying

```bash
sudo crontab -l
sudo /usr/local/sbin/jengasec-check-certificates ; echo "exit: $?"
sudo /usr/local/sbin/jengasec-check-disk ; echo "exit: $?"
sudo journalctl -u cron --since today
```

Run each script by hand at least once. **No output and exit 0 means healthy** —
that is the contract, and it is worth confirming rather than assuming, because
a script that is silently broken looks exactly the same as one with nothing to
report.

Confirm mail actually reaches someone. A `MAILTO` pointing at an address nobody
reads is the same as no `MAILTO` at all:

```bash
echo "test from $(hostname)" | mail -s "cron mail test" sucybersec@strathmore.edu
```
