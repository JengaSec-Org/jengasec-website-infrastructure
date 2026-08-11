# Roles

All 30 roles and their implementation status.

**16 implemented** (Phases 1–3) · **14 stubs** (Phases 4–10)

---

## Implemented

### Phase 1 — Base OS

| Role | Does |
|---|---|
| [`common`](../roles/common/README.md) | Packages, hostname, timezone, locale, NTP, unattended-upgrades, MOTD |
| [`os`](../roles/os/README.md) | Sysctls, resource limits, swap, journal caps, module blacklist |
| [`users`](../roles/users/README.md) | Service accounts, SSH keys, sudo policy |
| [`ssh`](../roles/ssh/README.md) | Hardened sshd — key-only, no root, VERBOSE logging |
| [`python`](../roles/python/README.md) | Python 3.11, pip config, virtualenv tooling |
| [`git`](../roles/git/README.md) | Git, system config, host key trust |
| [`systemd`](../roles/systemd/README.md) | Boot target, service hygiene, units, timers |

### Phase 2 — Networking

| Role | Does |
|---|---|
| [`networking`](../roles/networking/README.md) | Static addressing, resolver, routes. **Off by default** |
| [`firewall`](../roles/firewall/README.md) | UFW, data-driven ruleset, lockout protection |
| [`dns`](../roles/dns/README.md) | Bind9 — authoritative + recursive, restricted ACLs |
| [`dhcp`](../roles/dhcp/README.md) | isc-dhcp-server. **Off by default** |
| [`certificates`](../roles/certificates/README.md) | Internal CA (default), Let's Encrypt |

### Phase 3 — Security

| Role | Does |
|---|---|
| [`security`](../roles/security/README.md) | CIS-mapped hardening. Umbrella — pulls in the three below |
| [`fail2ban`](../roles/fail2ban/README.md) | Intrusion prevention, UFW ban action |
| [`audit`](../roles/audit/README.md) | auditd — identity, privilege, config, competition data |
| [`filesystem-security`](../roles/filesystem-security/README.md) | Permissions, ACLs, drift scans |

---

## Stubs

Every stub **fails loudly** rather than reporting success while doing nothing.
Its `defaults/main.yml` already defines the intended variable contract, so
`group_vars` written today keeps working when the tasks are filled in.

### Phase 4 — Application platform

| Role | Will do |
|---|---|
| [`nginx`](../roles/nginx/README.md) | Reverse proxy, TLS, security headers, rate limiting |
| [`gunicorn`](../roles/gunicorn/README.md) | WSGI server, systemd unit and socket |
| [`django`](../roles/django/README.md) | Clone, venv, `.env`, migrate, collectstatic |
| [`redis`](../roles/redis/README.md) | Cache, sessions, future Celery broker |

### Phase 5 — Database

| Role | Will do |
|---|---|
| [`postgresql`](../roles/postgresql/README.md) | Server, tuning, `pg_hba`, databases, roles, replication |

### Phase 6 — High availability

| Role | Will do |
|---|---|
| [`loadbalancer`](../roles/loadbalancer/README.md) | HAProxy, health checks, sticky sessions |

### Phase 7 — Operations

| Role | Will do |
|---|---|
| [`monitoring`](../roles/monitoring/README.md) | Prometheus, Grafana, node_exporter |
| [`logging`](../roles/logging/README.md) | Journal retention, logrotate, remote forwarding |
| [`deployment`](../roles/deployment/README.md) | Release, health check, rollback |
| [`cron`](../roles/cron/README.md) | Scheduled maintenance |

### Phase 8 — Storage

| Role | Will do |
|---|---|
| [`storage`](../roles/storage/README.md) | Filesystem layout, mounts, quotas |
| [`minio`](../roles/minio/README.md) | S3-compatible object storage |

### Phase 9 — Public access

| Role | Will do |
|---|---|
| [`cloudflare`](../roles/cloudflare/README.md) | Tunnel, DNS API, WAF rules |

### Phase 10 — Continuity

| Role | Will do |
|---|---|
| [`backup`](../roles/backup/README.md) | pg_dump, rsync, encryption, retention, verified restore |

---

## Suggested implementation order

Not the same as the phase numbers. This is what actually unblocks the most work
next:

1. **`postgresql`** — nothing else in Phase 4 is useful without it
2. **`gunicorn`** then **`django`** then **`nginx`** — in that order, so nginx
   never proxies to a socket that does not exist
3. **`backup`** — before the platform holds data anyone would miss
4. **`monitoring`** and **`logging`** — you want these before the event, not after
5. **`redis`** — only when sessions or caching become a real constraint
6. **`storage`**, **`deployment`**, **`cron`** — quality of life
7. **`loadbalancer`**, **`minio`**, **`cloudflare`** — only if the club grows into them

## Implementing a stubbed role

1. **`defaults/main.yml` first.** Every value the role needs. Nothing literal
   in tasks. The stub already has a starting contract — refine it.
2. **Templates second.** Every managed file is a `.j2` starting with
   `{{ common_managed_banner }}`. Not `copy`, not `lineinfile`.
3. **Tasks third**, referencing only variables. Add `validate:` wherever the
   service offers a config checker — `nginx -t`, `postgres --check`. That single
   line is what stops a bad template taking a service down.
4. **Handlers** for anything needing a restart. Prefer `reload` where the
   service supports it.
5. **Delete the `fail` task**, flip `<role>_enabled` to `true` in defaults.
6. **Update this file** — move the role from Stubs to Implemented.
7. **Rewrite `README.md`.** Not a formality: it is where the reasoning lives,
   and the reasoning is what makes this repository worth reading.

Then:

```bash
make lint && make syntax
ansible-playbook -i inventories/development playbooks/<phase>.yml --check --connection=local
```

and against staging, **twice** — the second run must report zero changes.

## House rules

Worth knowing before writing a role here.

- **Variables, never literals**, in tasks.
- **Templates, never `lineinfile`**, for files Ansible owns. The one exception
  is `/etc/login.defs`, and it is explained where it happens.
- **One owner per file.** Two roles writing the same file will fight, and the
  result depends on run order. `os` owns sysctls; `ssh` owns sshd_config;
  `users` owns sudoers.
- **`validate:` wherever a checker exists.**
- **Guard anything that can lock you out** — assert before acting, verify after.
- **Idempotence is the pass criterion.** If a second run reports changes, the
  role is wrong, even if the server looks right.
- **Explain the why, not the what.** `# install nginx` above a task that
  installs nginx is noise. `# reload, not restart, so existing sessions survive`
  is the comment worth writing.
