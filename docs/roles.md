# Roles

All 31 roles and their implementation status.

For what these roles actually do to a server, and what you must configure before
running them, see [pre-deployment.md](pre-deployment.md).

**All 31 implemented.** No stubs remain.

Seven roles are implemented but **off by default**, because turning them on is a
decision rather than a default: `networking`, `dhcp`, `loadbalancer`, `storage`,
`minio`, `cloudflare`, and `tailscale`. Each says why in its own README.

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

### Phase 4 — Application platform

| Role | Does |
|---|---|
| [`redis`](../roles/redis/README.md) | Cache and session store. Memory-capped, command-renamed, sandboxed |
| [`gunicorn`](../roles/gunicorn/README.md) | systemd **socket + service** pair, worker tuning, graceful reload |
| [`django`](../roles/django/README.md) | Checkout, virtualenv, `.env`, migrations, collectstatic |
| [`nginx`](../roles/nginx/README.md) | TLS, **load balancing**, static/media, rate limiting, security headers |

### Phase 5 — Database

| Role | Does |
|---|---|
| [`postgresql`](../roles/postgresql/README.md) | Server, RAM-proportional tuning, `pg_hba`, databases, roles |

### Phase 6 — High availability

| Role | Does |
|---|---|
| [`loadbalancer`](../roles/loadbalancer/README.md) | HAProxy tier for **multiple nginx hosts**. Off — nginx balances already |

### Phase 7 — Operations

| Role | Does |
|---|---|
| [`logging`](../roles/logging/README.md) | logrotate and rsyslog. Journald belongs to `os` |
| [`monitoring`](../roles/monitoring/README.md) | Prometheus, node_exporter, Grafana, alert rules |
| [`cron`](../roles/cron/README.md) | Certificate expiry, disk checks, temp cleanup |
| [`deployment`](../roles/deployment/README.md) | Release, health check, rollback |

### Phase 8 — Storage

| Role | Does | Default |
|---|---|---|
| [`storage`](../roles/storage/README.md) | Mount points, fstab, quotas, disk guards | **off** — nothing to mount on local disks |
| [`minio`](../roles/minio/README.md) | S3-compatible object storage | **off** — local disk plus nginx already works |

### Phase 9 — Off-campus access

| Role | Does | Default |
|---|---|---|
| [`cloudflare`](../roles/cloudflare/README.md) | Tunnel + Access, so the platform is reachable off campus | **off** — needs a Cloudflare account, zone and tunnel first |
| [`tailscale`](../roles/tailscale/README.md) | Tailnet node + subnet router, so the *organisers* can reach the servers and the lab LAN off campus | **off** — needs a Tailscale account and auth key; v1 turns it on |

### Phase 10 — Continuity

| Role | Does | Default |
|---|---|---|
| [`backup`](../roles/backup/README.md) | Pull-based encrypted backups, retention, verified restores | **on** |

---

## The seven that are off by default

Not unfinished — implemented, and switched off because enabling them is a
decision:

| Role | Why off | Turn on when |
|---|---|---|
| `networking` | Reconfigures the interface you are connected over | The installer's addressing is not enough |
| `dhcp` | A second DHCP server breaks a shared LAN for everyone | You have an isolated competition segment |
| `loadbalancer` | nginx balances Django already | You outgrow one nginx host |
| `storage` | Nothing to mount on three local disks | You add a volume |
| `minio` | Local disk plus nginx already works, and its updates are manual | Submissions outgrow one disk |
| `cloudflare` | Exposes the platform to the internet | The Cloudflare prerequisites exist — see the runbook |
| `tailscale` | Every device on the tailnet gets a route to this host and the LAN behind it | You need to administer the servers from off campus — see the runbook §9b |

## Adding a role

1. **`defaults/main.yml` first.** Every value the role needs. Nothing literal
   in tasks.
2. **Templates second.** Every managed file is a `.j2` starting with
   `{{ common_managed_banner }}`. Not `copy`, not `lineinfile`.
3. **Tasks third**, referencing only variables. Add `validate:` wherever the
   service offers a config checker — `nginx -t`, `haproxy -c -f`,
   `promtool check config`, `visudo -cf`, `cloudflared ingress validate`. That
   single line is what stops a bad template taking a service down.
4. **Handlers** for anything needing a restart. Prefer `reload` where the
   service supports it, and say in a comment why the other one is wrong.
5. **Guard anything destructive or lockout-capable** — assert before acting,
   verify after, and make the failure message name the fix.
6. **Add it to this file** and to `docs/pre-deployment.md`.
7. **Write `README.md`.** Not a formality: it is where the reasoning lives, and
   the reasoning is what makes this repository worth reading.

Then:

```bash
python tests/structure-check.py
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
  result depends on run order. `os` owns sysctls and journald; `ssh` owns
  sshd_config; `users` owns sudoers; `nginx` owns `/etc/nginx`; `loadbalancer`
  owns `/etc/haproxy`; `logging` owns logrotate and rsyslog.
- **`validate:` wherever a checker exists.**
- **Guard anything that can lock you out** — assert before acting, verify after.
- **Reload beats restart** wherever the service supports it, and the handler
  should say why.
- **Idempotence is the pass criterion.** If a second run reports changes, the
  role is wrong, even if the server looks right.
- **Explain the why, not the what.** `# install nginx` above a task that
  installs nginx is noise. `# reload, not restart, so existing sessions survive`
  is the comment worth writing.
