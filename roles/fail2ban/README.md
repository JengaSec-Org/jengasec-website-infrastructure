# `fail2ban`

**Phase 3 · Implemented**

Reads logs, matches failure patterns, and adds a temporary firewall ban for the
offending address.

## What it is actually for here

With SSH password authentication disabled by the [`ssh`](../ssh/README.md) role,
fail2ban is **not** what keeps attackers out of SSH — key authentication does
that, structurally.

What it buys is:

1. **A readable auth log.** Background scanning stops after three attempts
   instead of running all day.
2. **Real protection where credentials are genuinely submitted** — the Django
   login form and the admin interface. That is the jail that matters for
   JengaSec, because those accounts control scoring.

## `ignoreip` is the most important setting

```yaml
fail2ban_ignoreip:
  - 127.0.0.1/8
  - "{{ jengasec_network_cidr }}"
```

Without the LAN in that list, a mistyped password from a club laptop bans the
address you administer from — and fail2ban has no idea a competition is running.

If your control node is not on that subnet, **add it explicitly**.

## Two Debian 12 details that bite people

**`backend = systemd`.** Debian 12 has no `/var/log/auth.log`; it is all in the
journal. A jail pointed at a file that does not exist starts cleanly and never
matches anything — which is worse than no jail, because it looks like it is
working. The role's verification step exists to catch exactly this.

**`banaction = ufw`.** The default iptables action alongside UFW means two tools
writing the same tables, and rules that appear or vanish depending on which one
reloaded last.

## Jails

| Jail | Where | Notes |
|---|---|---|
| `sshd` | everywhere | 3 attempts, 2-hour ban |
| `nginx-http-auth` | `web` | Failed HTTP basic auth |
| `nginx-botsearch` | `web` | Probes for `/wp-admin`, `/.env` — 2 attempts, since none of those exist on a Django app and a request is never a mistake |
| `nginx-limit-req` | `web` | Clients tripping nginx's own rate limit |
| `django-auth` | `web`, **off** | See below |

Jails for services a host does not run are **omitted entirely**, not written
with `enabled = false` — fail2ban refuses to start if a jail names a log file
that does not exist, so an nginx jail on the database server would take the
whole service down.

## Enabling the Django jail

`fail2ban_django_enabled: false`, because **it does not work on its own**.

Django does not log authentication failures with the client IP out of the box.
The platform needs a receiver on the `user_login_failed` signal that writes one.
The full snippet is in the header comment of
[`templates/filter-django-auth.conf.j2`](templates/filter-django-auth.conf.j2).

The critical part of that snippet is the `X-Forwarded-For` handling. Behind
nginx, `REMOTE_ADDR` is `127.0.0.1` for **every** request — so a naive
implementation bans the loopback address and locks out every user at once,
during the event, with no obvious cause.

Test before trusting it:

```bash
fail2ban-regex /var/log/jengasec/django.log /etc/fail2ban/filter.d/django-auth.conf
```

## Escalating bans

`bantime.increment` doubles the ban each time, to a maximum of a week. Someone
probing five times in an hour is background noise; someone still at it on day
three should not get a fresh hour each time.

## Variables

| Variable | Default |
|---|---|
| `fail2ban_ignoreip` | loopback + LAN |
| `fail2ban_bantime` | `3600` |
| `fail2ban_findtime` | `600` |
| `fail2ban_maxretry` | `5` |
| `fail2ban_backend` | `systemd` |
| `fail2ban_banaction` | `ufw` |
| `fail2ban_sshd_maxretry` | `3` |
| `fail2ban_django_enabled` | `false` |
| `fail2ban_action_email` | `false` |

## Tags

`fail2ban`, `packages`, `config`, `service`, `verify`

## Verifying

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
sudo journalctl -u fail2ban -f
```

`Total failed: 0` on a host that has been up for days usually means the jail is
not reading anything, not that nothing has tried. The role warns about this
after 24 hours of uptime.

## Unbanning

```bash
sudo fail2ban-client set sshd unbanip 10.0.0.55
sudo fail2ban-client unban --all
```

Worth knowing before you need it.
