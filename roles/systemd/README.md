# `systemd`

**Phase 1 · Implemented**

The shared systemd baseline: boot target, manager defaults, service hygiene,
and a place for custom units and timers.

## Why systemd and not containers

Deployment here is native systemd. With 8 GB and 4 GB of RAM, a Docker or
Kubernetes layer costs memory and debugging effort without buying anything a
university-scale competition needs.

systemd already provides supervision, restart policy with backoff, dependency
ordering, resource limits, journal logging, and a sandbox — which is most of
what people reach for containers to get. See
[docs/decisions.md](../../docs/decisions.md).

Individual units (gunicorn, nginx, node_exporter) belong to their own roles.
This one owns the shared baseline.

## Two things people get wrong

**A disabled service with an enabled socket still starts.** Socket activation
launches it on the first connection. Disabling `cups.service` and assuming CUPS
is gone, while `cups.socket` is still enabled, is a common and quiet mistake —
so `systemd_disabled_sockets` exists as a separate list.

**systemd does not notice a new unit file.** Adding one to
`/etc/systemd/system/` without `daemon-reload` gives you `Unit not found` for a
file you can plainly see on disk. The role's handler covers it, and
`flush_handlers` forces the reload before units are enabled in the same run.

## What it does

| Area | Detail |
|---|---|
| Boot target | `multi-user.target` — never graphical |
| Timeouts | 60s start, 30s stop, so a hung service cannot stall a reboot |
| Restart policy | 5 failures in 60s, then stop — a crash loop produces a gigabyte of journal and hides the real error |
| Accounting | CPU, memory, IO, tasks per unit |
| `DefaultTasksMax` | 4096 — bounds a fork bomb to one unit |
| Disabled | bluetooth, cups, avahi, ModemManager, plus their sockets |
| Reporting | Prints any failed unit on every run |

Journal sizing is **not** here — it belongs to the `os` role
(`os_journald_max_use`), so there is one place to change it.

## Failed unit reporting

Every run ends by listing failed units. A failed unit nobody noticed is how a
backup silently stops running for three weeks; making it visible on every play
costs one command.

## Adding a unit or timer

```yaml
systemd_timers:
  - name: jengasec-cleanup.timer
    content: |
      [Unit]
      Description=Clean up stale submission temp files

      [Timer]
      OnCalendar=daily
      Persistent=true
      RandomizedDelaySec=300

      [Install]
      WantedBy=timers.target
```

Prefer timers over cron for anything systemd already supervises: you get journal
logging, dependency ordering, `Persistent=true` to catch up after downtime, and
`RandomizedDelaySec` so three servers do not all fire at the same instant.

## Variables

| Variable | Default |
|---|---|
| `systemd_default_target` | `multi-user.target` |
| `systemd_default_timeout_start_sec` | `60` |
| `systemd_disabled_services` | bluetooth, cups, avahi, ModemManager |
| `systemd_disabled_sockets` | avahi, cups |
| `systemd_enabled_services` | journald, timesyncd, cron |
| `systemd_units` / `systemd_timers` | `[]` |
| `systemd_accounting_enabled` | `true` |

## Tags

`systemd`, `config`, `target`, `services`, `units`, `timers`, `verify`

## Verifying

```bash
systemctl get-default
systemctl list-units --state=failed
systemctl list-timers --all
systemctl show --property=DefaultTasksMax
systemd-cgtop -n 1
```
