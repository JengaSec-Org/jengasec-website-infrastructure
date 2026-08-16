# jengasec-website-infrastructure

Ansible automation that builds and maintains the servers behind **JengaSec 2026** —
the Strathmore Cybersecurity Club's enterprise cybersecurity simulation.

Everything a JengaSec server *is* — its packages, users, firewall, DNS, hardening,
and the application itself — is described here as code. No server is configured by
hand. If a box is lost, it is rebuilt by re-running these playbooks, not by
remembering what was done to it.

This repository is also meant to be **read**. Club members should be able to open any
role and understand what it does to a Linux system and why, so the infrastructure
doubles as teaching material.

---

## What it manages

| Domain | Roles |
|---|---|
| Core | `common`, `os`, `systemd` |
| Networking | `networking`, `dns`, `dhcp`, `firewall`, `loadbalancer` |
| Security | `security`, `ssh`, `fail2ban`, `audit`, `filesystem-security`, `certificates`, `cloudflare` |
| Identity | `users` |
| Application | `python`, `django`, `gunicorn`, `nginx`, `redis` |
| Database | `postgresql` |
| Storage | `storage`, `minio` |
| Observability | `monitoring`, `logging` |
| Continuity | `backup` |
| Automation | `deployment`, `git`, `cron` |

**All thirty roles are implemented.** Six are switched off by default, because
enabling them is a decision rather than a default — see
[docs/roles.md](docs/roles.md).

## Servers

| Host | Function | Notes |
|---|---|---|
| `server1` | Web — nginx, gunicorn, Django | 8 GB RAM, the workhorse |
| `server2` | Database + DNS/DHCP — PostgreSQL, Redis, Bind9 | 4 GB RAM |
| `server3` | Backup + monitoring | Prometheus/Grafana, backup target |

Hosts are grouped by **function**, not by machine name, so moving a service between
boxes is an inventory edit rather than a rewrite.

## How a request flows

Two paths, one platform.

```
off campus →  Cloudflare edge  →  cloudflared  ─┐
              WAF · Access on /admin/           │
                                                ▼
on campus  ─────────────────────────────────► nginx    TLS, rate limit,
                                                │      static/media, LOAD BALANCE
                                                ▼
                                             gunicorn  unix socket, N workers
                                                ▼
                                              Django
                                                ▼
                                    PostgreSQL · Redis  (server2)
```

**The tunnel means no inbound port.** `cloudflared` dials out to Cloudflare and
holds the connection open, so the origin never appears in public DNS and is
invisible to internet scanning. Port 80 is closed and 443 is restricted to the
competition LAN.

**nginx is the load balancer.** Adding a second application host is an edit to
`nginx_upstream_servers`, not a new service. The `loadbalancer` role is a separate
HAProxy tier for when one nginx is no longer enough — off by default.

**Backups pull.** server3 reaches out to the others; they have no route into it,
so a compromised web host cannot delete its own backups.

## Design decisions

- **Debian 12 (Bookworm)** everywhere.
- **No Docker, no Kubernetes.** With 8 GB and 4 GB of RAM, a native
  nginx + gunicorn + PostgreSQL + Redis stack managed by systemd is lighter, easier to
  debug, and entirely sufficient for a university-scale competition.
- **UFW** for the firewall, with the ruleset expressed as data in `group_vars`.
- **Everything is a variable, every config file is a Jinja2 template.** No literal
  ports, paths, or package names inside tasks.

The reasoning behind each is in [docs/decisions.md](docs/decisions.md).

---

## Quick start

Ansible has no supported Windows control node. Run these from the Debian machine.

```bash
sudo apt update && sudo apt install -y ansible-core git make yamllint
ansible-galaxy collection install -r requirements.yml
```

Then, before anything touches a server:

```bash
make lint && make syntax
```

### Checking the repo without Ansible

`tests/structure-check.py` validates the whole repository — every YAML file,
every Jinja2 template, every variable, template, role, and handler reference —
using only `pyyaml` and `jinja2`.

**No Ansible, so it runs on Windows too**, which is where it earns its keep:
catching a missing template or a typo'd variable *before* you copy anything to
the Debian box.

```bash
python tests/structure-check.py
```

It proves the repository is well formed. It does not prove a run will succeed —
for that you need `make check` on the control node.

**Fill in the inventory.** Every value that must change is marked `# TODO: replace`:

```bash
grep -rn "TODO: replace" inventories/production/
```

Edit `inventories/production/host_vars/*.yml` (addresses, gateway, interface) and
`inventories/production/group_vars/all/main.yml` (domain, network). Then create the
vault from the example:

```bash
cp inventories/production/vault.yml.example inventories/production/vault.yml
ansible-vault encrypt inventories/production/vault.yml
```

Add your SSH public key to `roles/users/files/ssh-keys/` — see the README there.

Confirm the control node can reach everything:

```bash
make preflight
make ping
```

## Running it

Phases run **in order**, one at a time, verifying between each. Never run
`make site` against a server you have not bootstrapped.

```bash
make bootstrap LIMIT=server1     # Phase 1 — base OS
make security  LIMIT=server1     # Phase 3 — hardening
make networking LIMIT=server1    # Phase 2 — network, firewall, DNS, TLS
make database  LIMIT=server2     # Phase 5 — PostgreSQL
make platform  LIMIT=server1     # Phase 4 — Redis, gunicorn, Django, nginx
make monitoring                  # Phase 7 — logging, Prometheus, Grafana
make backup    LIMIT=server3     # Phase 10 — encrypted pull backups
make cloudflare LIMIT=server1    # Phase 9 — the tunnel; read the runbook first
```

Run each a second time. **It must report zero changed tasks** — that is the pass
criterion. An Ansible run that keeps changing things on every execution is not
describing the system, it is fighting it.

> **Keep a physical or out-of-band console open** while running the `ssh`, `firewall`,
> and `networking` roles. Each one can end the SSH session you are running from.
> [docs/runbook.md](docs/runbook.md) covers the recovery steps.

## Layout

```
ansible.cfg          control node configuration
site.yml             every phase, in order
requirements.yml     Galaxy collections
inventories/         production, staging, development, lab
playbooks/           one per phase
roles/               30 roles
files/               shared static assets
scripts/             preflight and helpers
docs/                pre-deployment, runbook, decisions, secrets, variables, roles
tests/               syntax and structure checks
```

## Documentation

| Document | Purpose |
|---|---|
| **[docs/lab-setup.md](docs/lab-setup.md)** | **Try it first.** Four VirtualBox VMs on a laptop — build, run, and break it safely |
| **[docs/pre-deployment.md](docs/pre-deployment.md)** | What this will do to real servers, and everything you must configure first |
| [docs/runbook.md](docs/runbook.md) | How to actually deploy, phase by phase, with recovery steps |
| [docs/variables.md](docs/variables.md) | Variable precedence and every `group_vars` key |
| [docs/secrets.md](docs/secrets.md) | ansible-vault workflow |
| [docs/decisions.md](docs/decisions.md) | Why the stack looks like this |
| [docs/roles.md](docs/roles.md) | All 30 roles and their implementation status |

## Contributing

Branch from `main`, open a pull request — same workflow as the platform repo.

Before pushing:

```bash
python tests/structure-check.py && make lint && make syntax
```

When you implement a stubbed role, work through
[docs/roles.md](docs/roles.md#implementing-a-stubbed-role): fill `defaults/main.yml`
first, write templates second, tasks last, then delete the `fail` guard and update the
status table.

---

Strathmore Cybersecurity Club · Nairobi
