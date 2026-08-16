# `logging`

**Phase 7 · Implemented**

Log rotation and syslog routing.

## What this role does *not* own

**Journald.** The [`os`](../os/README.md) role owns
`/etc/systemd/journald.conf.d` via `os_journald_max_use` and friends.

Two roles writing one file is the collision the house rules forbid, and the
symptom here would be a journal size cap that changes depending on which role
ran last. To change journal retention, edit the `os` role's variables.

This role owns **logrotate and rsyslog**. That is the whole boundary.

## `postrotate` is the point

A daemon holding an open file descriptor keeps writing to the rotated-away
inode. The new file stays empty, the old one grows invisibly, and the disk fills
with a file `ls` no longer shows where you expect it.

That is why nginx gets `kill -USR1` and Redis gets the same. gunicorn does not
need one — it logs to the journal.

`sharedscripts` runs `postrotate` **once** for the whole set rather than per
file. Without it, a wildcard matching five nginx logs signals nginx five times.

## No shared defaults file

There is deliberately no `00-jengasec-defaults` in `/etc/logrotate.d`.

Global directives in an included file apply to every file logrotate reads
**after** it, in alphabetical order — so a `00-` file silently changes the
behaviour of Debian's own rules for apt, dpkg and the rest. Each rule here is
self-contained instead: more repetition in the template, no action at a
distance.

## Rules are host-aware

Each entry carries a `when`, so the PostgreSQL rules land only on the database
host and the nginx rules only on the web host. A rule naming a path that never
exists is not an error, but it is noise in a directory someone will be reading
during an incident.

| Rule | Host | Keeps | Note |
|---|---|---|---|
| nginx | `web` | 30 days | Access logs are the incident record |
| jengasec | `web` | 30 days | Django's own file logger, if added |
| postgresql | `database` | 30 days | Backstop — the collector rotates too |
| redis | `database` | 7 days | Cache logs age out fast |

## Auth log

`logging_separate_auth_log` writes auth events to `/var/log/auth.log` as well as
the journal.

journalctl already has them, so why a file: it survives journal rotation, it can
be copied off the host without journalctl, and `sudo cp auth.log` is a lower bar
than teaching someone journalctl at 2am.

## Remote forwarding is off — consider turning it on

`logging_remote_enabled: false`, and this is the setting most worth revisiting
before the competition.

**Logs on a compromised host are evidence an attacker can edit.** Shipping them
elsewhere is the only way to have a copy they cannot reach. If the club stands
up a collector — Loki, Graylog, or plain rsyslog on server3 — turn this on.

Two details when you do:

- **Use TCP** (`@@`), not UDP. UDP silently drops messages under load, which is
  precisely when the log matters.
- **Leave the disk queue on.** Without it rsyslog buffers in memory and discards
  when full — and it fills fastest during exactly the incident you need.

## Validation

Both configurations are checked before anything restarts:

- `logrotate --debug` parses every rule and reports what it *would* do. A syntax
  error makes logrotate skip that file silently on its real run, so nothing
  rotates and nobody notices until the disk is full.
- `rsyslogd -N1` validates syntax without starting.

## Variables

| Variable | Default |
|---|---|
| `logging_logrotate_frequency` | `daily` |
| `logging_logrotate_rotate` | `14` |
| `logging_logrotate_configs` | 4 rules, host-scoped |
| `logging_rsyslog_enabled` | `true` |
| `logging_separate_auth_log` | `true` |
| `logging_remote_enabled` | `false` |
| `logging_remote_protocol` | `tcp` |

## Tags

`logging`, `packages`, `logrotate`, `rsyslog`, `permissions`, `service`,
`verify`

## Verifying

```bash
sudo logrotate --debug /etc/logrotate.conf
sudo rsyslogd -N1
ls -la /etc/logrotate.d/
du -sh /var/log
journalctl --disk-usage
```

Force a rotation to prove `postrotate` works:

```bash
sudo logrotate -f /etc/logrotate.d/jengasec-nginx
ls -l /var/log/nginx/
```

The new `access.log` should exist and be growing. If it stays at zero bytes
while a `.1` file keeps growing, the `postrotate` signal is not reaching nginx.
