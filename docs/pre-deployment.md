# Pre-deployment review

**Read this before running Ansible against real hardware.**

What this repository will do to your servers, what you must configure first, and
where it can go wrong. Everything here is checkable against the code — if
something below does not match, the code wins and this document is a bug.

---

## 1. What this is, and what it is not

**All 30 roles are implemented.** No stubs remain.

| Phase | Roles | Result |
|---|---|---|
| 1 — Base OS | `common`, `os`, `users`, `ssh`, `python`, `git`, `systemd` | A consistent, hardened Debian baseline |
| 2 — Networking | `networking`, `firewall`, `dns`, `dhcp`, `certificates` | Addressing, UFW, Bind9, internal CA |
| 3 — Security | `security`, `fail2ban`, `audit`, `filesystem-security` | CIS-mapped hardening, auditd, intrusion prevention |
| 4 — Platform | `redis`, `gunicorn`, `django`, `nginx` | The JengaSec platform, running |
| 5 — Database | `postgresql` | PostgreSQL 15, tuned for 4 GB |
| 6 — HA | `loadbalancer` | HAProxy tier — **off**, nginx balances already |
| 7 — Operations | `logging`, `monitoring`, `cron`, `deployment` | Rotation, Prometheus + Grafana, scheduled checks, releases |
| 8 — Storage | `storage`, `minio` | Mounts and object storage — **both off** |
| 9 — Public access | `cloudflare` | **Tunnel + Access — reachable off campus** |
| 10 — Continuity | `backup` | Encrypted pull backups with verified restores |

### Six roles are off by default

Not unfinished — implemented, and switched off because enabling them is a
decision rather than a default:

| Role | Turn on when |
|---|---|
| `networking` | The installer's addressing is not enough |
| `dhcp` | You have an isolated competition segment |
| `loadbalancer` | You outgrow one nginx host |
| `storage` | You add a volume to mount |
| `minio` | Submissions outgrow the local disk |
| `cloudflare` | The Cloudflare prerequisites exist — **required for off-campus access** |

---

## 2. Platform-side changes

**Two files in `../jengasec-competition-platform` were changed.** They are in a
different repository with its own review and its own commit, and they are
**uncommitted** there.

None of this could be fixed from the infrastructure side.

### `config/settings.py`

| Added | Why |
|---|---|
| `SECURE_PROXY_SSL_HEADER` | Behind nginx Django sees plain HTTP. Without this, `request.is_secure()` is false and secure cookies are never set. |
| `CSRF_TRUSTED_ORIGINS` | **Django 4+ rejects every login POST whose `Origin` is not listed** — with a CSRF error that does not name the cause. The site would deploy cleanly and be unusable. |
| Secure cookies, nosniff, X-Frame-Options, when `DEBUG` is off | Defence in depth alongside the nginx headers |

`SECURE_SSL_REDIRECT` is deliberately **not** set. nginx already redirects, and
both together produce a redirect loop whenever the proxy header is
misconfigured — which the browser reports only as "too many redirects".

### `config/urls.py`

A real `/healthz/` endpoint that runs `SELECT 1` and returns 200 or 503.

The landing page at `/` is a `TemplateView` touching no database — it returns
200 with PostgreSQL completely down. A load balancer trusting that keeps routing
traffic to a backend that cannot serve a single real page, which is worse than
no health check at all.

### What was not changed

**WhiteNoise stays unwired.** nginx serves static from disk, which is faster and
means one owner for those files. Enabling the middleware too would give the same
files two servers with different cache headers.

### The guard

The `django` role greps the checkout for these settings and **refuses to
deploy** without them. An old checkout fails the play rather than the login page.

---

## 3. How a request flows

Two paths reach the same platform.

```
OFF CAMPUS                              ON CAMPUS
  │                                       │
  ▼                                       │
Cloudflare edge                           │
  │  WAF, rate limiting                   │
  │  Access identity check on /admin/     │
  ▼                                       │
  ╎ outbound tunnel, no inbound port      │  direct, LAN only
  ▼                                       ▼
cloudflared ─────────────────────────► nginx ──── TLS
                     https://127.0.0.1   │        rate limit (/login/ 5/min)
                                         │        /static/ from disk
                                         │        /media/  forced download
                                         │        LOAD BALANCING
                                         ▼
                              gunicorn ── unix socket, N workers
                                         ▼
                                      Django
                                         │
                              ┌──────────┴──────────┐
                              ▼                     ▼
                        PostgreSQL              Redis
                     (server2, web host only)
```

**nginx is the load balancer.** `least_conn` across `nginx_upstream_servers` —
today one local gunicorn socket, and adding a second application host is an edit
to that list. `least_conn` rather than round-robin because request durations
here are wildly uneven: a page view takes milliseconds, an AI evaluation takes a
minute.

Health checks are **passive** — nginx open source never probes an idle backend,
it learns from real requests failing. The `loadbalancer` role (HAProxy, active
checks) exists for when one nginx is no longer enough. It is off.

### The tunnel changes the network model

`cloudflared` dials **out** to Cloudflare and holds the connection open.
Requests arrive down that existing connection, so **no inbound port is involved
at all**.

| | |
|---|---|
| The origin's address never appears in public DNS | Nothing to scan for |
| A campus firewall blocking inbound stops mattering | And you do not have to ask for an exception |
| Cloudflare's WAF sits in front | Free tier |

That is why **80 is closed and 443 is restricted to the LAN**. Re-opening either
to `any` would throw the benefit away.

**Split-horizon naming:** `platform.jengasec.local` internally via Bind9,
`platform.<public domain>` via the tunnel. Both are in nginx's `server_name`,
Django's `ALLOWED_HOSTS`, and `CSRF_TRUSTED_ORIGINS`.

---

## 4. What happens to each server

| | server1 | server2 | server3 |
|---|---|---|---|
| **Function** | Web | Database + DNS/DHCP | Backup + monitoring |
| **RAM** | 8 GB | 4 GB | — |
| **Phases 1–3** | ✅ | ✅ | ✅ |
| **Phase 4** | redis¹, gunicorn, django, nginx | — | — |
| **Phase 5** | — | **PostgreSQL** | — |
| **Phase 7** | logging, node_exporter, cron | logging, node_exporter, cron | logging, node_exporter, cron, **Prometheus + Grafana** |
| **Phase 9** | **cloudflared** — the tunnel | — | — |
| **Phase 10** | — | — | **backup** — pulls from the other two |
| **Swap** | 2 GB | 4 GB | 2 GB |
| **Tuning** | 9 gunicorn workers max | `vm.swappiness=1`; shared_buffers 1 GB | disk warning at 75% |

¹ Redis is defined in `group_vars/database`, so it lands on server2 in this
inventory.

### Ports

**Nothing is open to the internet.**

| Port | server1 | server2 | server3 | Purpose |
|---|---|---|---|---|
| 22 | LAN | LAN | LAN | SSH, rate-limited |
| 443 | **LAN only** | — | — | The platform, on campus |
| 80 | **closed** | — | — | nginx still redirects; the rule is gone |
| 53 | — | LAN | — | DNS |
| 67 | — | any² | — | DHCP |
| 5432 | — | **server1 only** | — | PostgreSQL |
| 6379 | — | **server1 only** | — | Redis |
| 9100 | server3 | server3 | server3 | node_exporter |
| 3000 / 9090 | — | — | LAN | Grafana / Prometheus |
| 873 | — | — | LAN | rsync backup ingest |
| **outbound 7844** | ✓ | — | — | **The tunnel.** UDP for QUIC, falling back to TCP 443 |

² Only if you enable DHCP, which is off by default.

**Two rules matter most.**

`5432` — PostgreSQL is not reachable from the LAN, only from the web host.

`443 LAN-only` — off-campus traffic arrives through the tunnel instead, so the
origin is invisible to internet-wide scanning. Widening this to `any` undoes the
main reason for running a tunnel.

If the campus blocks outbound UDP 7844, set `cloudflare_protocol: http2` to fall
back to TCP 443.

### Services

**Enabled:** `ssh`, `ufw`, `fail2ban`, `auditd`, `apparmor`, `acct`,
`systemd-timesyncd`, `cron`, `systemd-journald`, `rsyslog`,
`prometheus-node-exporter` — plus `nginx`, `gunicorn.socket`, `gunicorn`,
`cloudflared` on server1; `postgresql`, `redis-server`, `named` on server2;
`prometheus`, `grafana-server`, `jengasec-backup.timer`,
`jengasec-backup-verify.timer` on server3.

**Disabled:** `bluetooth`, `cups`, `avahi-daemon`, `ModemManager`, and their
sockets separately — a disabled service with an enabled socket still starts on
first connection.

---

## 5. Files created or modified

Roughly 95 files. The Phase 1–3 list is unchanged; what Phases 4–10 add:

> **Five roles replace a file wholesale** rather than adding a drop-in: `ssh`,
> `dns`, `dhcp`, `postgresql` (both config files), and `nginx` (`nginx.conf`).
> **Hand-edits to those are destroyed on the next run.** All keep timestamped
> backups.

| Role | Path | Note |
|---|---|---|
| `postgresql` | `/etc/postgresql/15/main/postgresql.conf` | **Replaced.** Memory tuning, logging, timeouts |
| | `/etc/postgresql/15/main/pg_hba.conf` | **Replaced.** Order is load-bearing — first match wins |
| `redis` | `/etc/redis/redis.conf` | Bind, password, memory cap, renamed commands |
| | `…/redis-server.service.d/60-jengasec.conf` | systemd sandboxing |
| `gunicorn` | `/etc/systemd/system/gunicorn.socket` | Socket, `jengasec:www-data` mode 0660 |
| | `/etc/systemd/system/gunicorn.service` | Workers, timeouts, sandboxing |
| `django` | `/opt/jengasec/app/` | The checkout |
| | `/opt/jengasec/venv/` | Virtualenv |
| | `/opt/jengasec/.env` | **Secret key and DB password.** 0640 |
| | `…/app/staticfiles/` | `collectstatic` output |
| `nginx` | `/etc/nginx/nginx.conf` | **Replaced.** Workers, gzip, rate-limit zones |
| | `/etc/nginx/sites-available/jengasec.conf` | Upstream, TLS, static, media, locations |
| | `/etc/nginx/snippets/jengasec-proxy.conf` | Proxy headers, keepalive |
| | `/etc/nginx/snippets/jengasec-security-headers.conf` | HSTS, CSP, nosniff |
| `logging` | `/etc/logrotate.d/jengasec-*` | Per-app rotation, host-scoped |
| | `/etc/rsyslog.d/50-jengasec.conf` | Auth log, app routing |
| `monitoring` | `/etc/default/prometheus-node-exporter` | Bind address, collectors |
| | `/etc/prometheus/prometheus.yml` | Scrape config from the inventory |
| | `/etc/prometheus/rules/jengasec.yml` | 9 alert rules |
| | `/etc/default/prometheus` | Retention — **flags, not config file** |
| | `/etc/grafana/grafana.ini` | Admin password, anonymous off |
| | `/etc/apt/keyrings/grafana.asc` | Third-party repo key |
| `cron` | `/usr/local/sbin/jengasec-check-*` | Certificate, disk, cleanup scripts |
| | root crontab | Three scheduled jobs |
| `deployment` | `/opt/jengasec/.deploy/releases.log` | What was deployed, when |
| `loadbalancer` | `/etc/haproxy/haproxy.cfg` | Only if enabled |
| `cloudflare` | `/etc/cloudflared/config.yml` | Ingress rules; the catch-all is mandatory |
| | `/etc/cloudflared/token` | **Authenticates this host as the tunnel.** 0600 |
| | `/etc/systemd/system/cloudflared.service` | Sandboxed, `MemoryDenyWriteExecute` |
| | `/etc/apt/keyrings/cloudflare-main.gpg` | Second third-party repo key |
| `backup` | `/srv/backup/{daily,weekly,monthly}` | 0700 — filenames alone reveal what exists |
| | `/usr/local/sbin/jengasec-backup` | The pull, compress, encrypt, rotate script |
| | `/usr/local/sbin/jengasec-restore` | Written before you need it |
| | `/usr/local/sbin/jengasec-backup-verify` | Monthly restore proof |
| | `/etc/systemd/system/jengasec-backup{,-verify}.{service,timer}` | `Persistent=true` |
| | `/etc/systemd/system/jengasec-backup-failed.service` | Mails on failure |
| | `/home/backup/.ssh/id_ed25519` | The pull key, generated here |
| `storage` | `/etc/fstab` entries | Only if `storage_mounts` is set |
| `minio` | `/etc/default/minio`, `/srv/minio` | Only if enabled |

---

## 6. Packages

Phases 1–3 install about 50. Phases 4–7 add:

| Group | Host | Packages |
|---|---|---|
| PostgreSQL | server2 | `postgresql-15`, client, contrib, `python3-psycopg2` |
| Redis | server2 | `redis-server`, `redis-tools` |
| Web | server1 | `nginx` |
| Logging | all | `rsyslog`, `logrotate` |
| Monitoring | all | `prometheus-node-exporter` |
| Monitoring | server3 | `prometheus`, `grafana` |
| Tunnel | server1 | `cloudflared` |
| Backup | server3 | `rsync`, `gnupg`, `postgresql-client-15` |
| HAProxy | — | `haproxy`, only if the LB tier is enabled |
| MinIO | — | pinned `.deb`, only if enabled |

**Two third-party APT sources**, each with its key pinned in
`/etc/apt/keyrings` and scoped with `signed-by=` so it can install that vendor's
packages and nothing else:

| Source | Package | Avoidable? |
|---|---|---|
| `apt.grafana.com` | grafana | Yes — `grafana_enabled: false`; Prometheus has a usable UI |
| `pkg.cloudflare.com` | cloudflared | Only by not being reachable off campus |

**MinIO goes the other way** — no repository exists, so it is a pinned `.deb`
with a checksum and its updates are manual. That is a real argument for leaving
it off, and it is why the role is disabled.

---

## 7. Configure first

**42 values need replacing.** Find them:

```bash
grep -rn "TODO: replace" inventories/production/
```

That returns 44 lines — two are comment-box text in `hosts.yml`, not values.

| File | Values | What |
|---|---|---|
| `hosts.yml` | 5 | Three addresses, `ansible_user`, key path |
| `host_vars/server1.yml` | 5 | Interface, address, netmask, DNS, cert IP |
| `host_vars/server2.yml` | 4 | Interface, address, netmask, cert IP |
| `host_vars/server3.yml` | 5 | Interface, address, netmask, DNS, cert IP |
| `group_vars/all/main.yml` | 5 | Internal domain, **public domain**, CIDR, gateway, admin key |
| `group_vars/dns/main.yml` | 11 | Forwarders, reverse zone, A and PTR records |
| `group_vars/dhcp/main.yml` | 6 | Subnet, pool, broadcast, nameserver |
| `group_vars/backup/main.yml` | 1 | GPG recipient |

> **`jengasec_public_domain` must be a real domain.** Cloudflare cannot serve
> `.local` — it is reserved for mDNS — and the `cloudflare` role refuses to
> start with one, because the failure at Cloudflare's end is opaque.

> **`networking_interface` is the one people get wrong.** Debian 12 uses
> `ens18`, `enp0s3`, `eno1` — **rarely `eth0`**. Check on the box:
> ```bash
> ip -brief link show
> ```
> The role asserts the interface exists, so a wrong name fails the play rather
> than the server.

### Also required, not marked TODO

- [ ] **An SSH public key** in `roles/users/files/ssh-keys/`, listed in
      `users_admin_ssh_keys`. The `users` role refuses to run without one.
- [ ] **`vault.yml`** from the example, encrypted. Now **19 keys**.
- [ ] **The platform-side changes** in section 2, or the `django` role refuses
      to deploy.
- [ ] **A superuser**, created by hand after Phase 4. Not automated — the
      password would have to live in a variable, and that account can change
      every score:
      ```bash
      sudo -u jengasec /opt/jengasec/venv/bin/python \
          /opt/jengasec/app/manage.py createsuperuser
      ```
- [ ] **A GPG public key** in `roles/backup/files/`, generated **somewhere other
      than server3** — the point is that the backup host cannot read what it
      stores. Keep the private key where more than one person can reach it.
- [ ] **The backup pull key**, which takes two passes: run the backup role, copy
      the key it prints into `users_backup_pull_key`, re-run
      `bootstrap.yml --tags backup-key`.

### Prerequisites that live outside this repository

For off-campus access, four things must exist **in Cloudflare** before the role
can do anything. `docs/runbook.md` step 9 walks through them.

- [ ] A Cloudflare account with your **real domain** added as a zone
- [ ] A tunnel — Zero Trust → Networks → Tunnels → Create
- [ ] Its token, into the vault as `vault_cloudflare_tunnel_token`
- [ ] A public hostname on the tunnel, pointing at `HTTPS 127.0.0.1:443`

For Access on `/admin/`, a **second** token with *Access: Apps and Policies —
Edit*. The tunnel token has no Access rights, and using one for the other fails
with an unhelpful 403.

---

## 8. The switches

### Phases 1–3

| Switch | Default | Why |
|---|---|---|
| `networking_configure` | `false` | Reconfigures the interface you are connected over |
| `dhcp_configure` | `false` | A second DHCP server breaks a shared LAN for everyone |
| `firewall_require_ssh_rule` | `true` | **Leave on.** Refuses to enable UFW without an SSH rule |
| `audit_immutable` | `false` | Turn on before the competition; needs a reboot |
| `users_ssh_exclusive` | `false` | Turn on once every member's key is committed |
| `certificates_provider` | `internal_ca` | No public CA will issue for `.local` |
| `python_build_from_source` | `false` | 3.11 runs Django 5 fine |
| `networking_ipv6_enabled` / `firewall_ipv6` | `false` | **Change together** |

### Phases 4–7

| Switch | Default | Why |
|---|---|---|
| `nginx_hsts_enabled` | `false` | **No server-side undo.** Ship it with a broken certificate and that browser cannot reach the site for a year |
| `nginx_csp_report_only` | `true` | A CSP that breaks the app is worse than none. Watch the console first |
| `nginx_sticky_sessions` | `false` | `ip_hash` *replaces* `least_conn` and buckets a whole campus onto one backend |
| `nginx_media_force_download` | `true` | **Leave on.** An uploaded SVG rendered inline executes script in the platform's origin |
| `django_require_proxy_settings` | `true` | **Leave on.** Catches an old checkout before the login page does |
| `django_superuser_create` | `false` | Its password would live in a variable |
| `redis_save_enabled` | `false` | Treated as a cache. RDB forks the process, doubling memory |
| `postgresql_archive_mode` | `false` | **Do not enable until `backup` exists** — unarchived WAL fills the disk and PostgreSQL stops accepting writes |
| `postgresql_replication_enabled` | `false` | A replica on the same host protects against nothing |
| `loadbalancer_enabled` | `false` | nginx balances already |
| `grafana_enabled` | `true` | Set false to avoid the third-party APT source |
| `grafana_anonymous_access` | `false` | Dashboards are useful reconnaissance |
| `logging_remote_enabled` | `false` | **Worth turning on** — logs on a compromised host are evidence an attacker can edit |
| `deployment_refuse_if_dirty` | `true` | Someone hot-fixed the server; deploying destroys the fix and the evidence |
| `deployment_rollback_on_failure` | `true` | Restores **code, not the database** |
| `deployment_maintenance_page` | `false` | A reload is a pause of a second or two |

### Phases 8–10

| Switch | Default | Why |
|---|---|---|
| `cloudflare_enabled` | `false` | **Turn this on for off-campus access.** Off until the Cloudflare prerequisites exist |
| `cloudflare_access_enabled` | `true` | Identity check on `/admin/` at the edge. Fails loudly if credentials are missing rather than skipping |
| `cloudflare_origin_no_tls_verify` | `false` | Verifying the origin against the internal CA, not just encrypting to it |
| `backup_enabled` | **`true`** | The one thing here that guards data nobody can recreate |
| `backup_encrypt` | `true` | The archive holds submissions and scores on a shared host |
| `backup_verify_enabled` | `true` | A backup never restored is a hope, not a backup |
| `storage_enabled` | `false` | Nothing to mount on three local disks |
| `storage_refuse_nonempty_mountpoint` | `true` | Mounting over files hides them; they reappear only on unmount |
| `minio_enabled` | `false` | Local disk plus nginx works, and MinIO's updates are manual |
| `users_backup_pull_enabled` | `false` | Turn on after pasting the key the backup role prints |

---

## 9. Where it can go wrong

### The three that can lock you out

| Role | Guards | Recovery |
|---|---|---|
| `ssh` | Refuses without an installed key · `sshd -t` validates before replacing · reloads, not restarts · verifies after | `cp /etc/ssh/sshd_config.<ts> …` then `systemctl reload ssh` |
| `firewall` | Asserts SSH is in the ruleset · applies it **first** · re-reads the live kernel ruleset after | `ufw disable && ufw allow 22/tcp && ufw enable` |
| `networking` | Off by default · asserts the interface exists · reconfigures one interface, not all | `ifdown eth0 --force`, move the drop-in aside, `ifup eth0` |

**fail2ban can also ban you** if `fail2ban_ignoreip` misses your address:
`fail2ban-client set sshd unbanip <address>`.

> **Have console access open** before Phase 2 — physical, iDRAC/iLO, or the
> hypervisor console. Not "available if needed". Open.

### The new ones

**502 from nginx.** Almost always the gunicorn socket permissions. The evidence
is in *nginx's* log, not gunicorn's, which sends people to the wrong service:

```bash
ls -l /run/gunicorn/gunicorn.sock        # want srw-rw---- jengasec www-data
sudo -u www-data curl --unix-socket /run/gunicorn/gunicorn.sock http://localhost/healthz/
```

**Login fails with a CSRF error.** The platform-side changes in section 2 are
missing, or `DJANGO_CSRF_TRUSTED_ORIGINS` in `.env` does not match the URL the
browser used — it must include the scheme.

**`migrate` fails with a permission error.** Since PostgreSQL 15 the `public`
schema is not writable by default. The role grants `CREATE, USAGE` to each
database owner; if you created the role by hand, it may not have it.

**Timeouts must stack outward:** Cloudflare 30s connect → HAProxy 200s → nginx
180s → gunicorn 120s. Each layer more patient than the one behind it, or the
outer one returns an error for work still in progress. The nginx role asserts
its half.

### Tunnel-specific

**cloudflared will not start.** Almost always a **missing catch-all ingress
rule** — it refuses to start without a final rule that has no hostname, and the
error does not mention ingress at all. The template always appends one; the role
runs `cloudflared ingress validate` before restarting.

**502 through Cloudflare, but the site works on the LAN.** The tunnel registered
and the origin did not answer. A tunnel with a dead origin registers perfectly
happily — the role checks the origin separately for this reason.

**525 or 526 from Cloudflare.** TLS between cloudflared and nginx failed.
Almost always `originServerName` not matching the certificate, so nginx serves
the default vhost instead of the JengaSec one.

**Tunnel will not register at all.** A token for a tunnel that was deleted and
recreated, or no outbound UDP 7844. Set `cloudflare_protocol: http2` to fall
back to TCP 443.

**Everyone locked out of `/admin/`.** The Access policy. Fixed in Cloudflare's
dashboard — Zero Trust → Access → Applications — not with Ansible. Test it from
a logged-out browser *before* the competition.

### Backup-specific

**Backups silently stop.** The reason `jengasec-backup-failed.service` exists: a
failing timer is otherwise visible only to whoever runs `journalctl`, and nobody
runs `journalctl` on a server that appears to be working. The Ansible run also
reports backup freshness every time.

**`jengasec-backup-verify` fails to decrypt.** Expected: the private key
deliberately is not on server3. Run the verification from the machine that holds
it, or import it temporarily and remove it afterwards.

**rsync fails with "permission denied".** The forced-command key is not
installed on the source host, or `users_backup_pull_from` does not match
server3's actual address.

---

## 10. Order of work

```
 0. python tests/structure-check.py          on Windows, before copying
 1. copy to Debian, install ansible-core + collections
 2. fill in the 42 TODO values
 3. vault.yml, SSH key, GPG key, platform-side changes
 4. ./scripts/preflight.sh
 5. dry run against the development inventory
 6. Phase 1  — bootstrap      server3 → server2 → server1
 7. Phase 3  — security       server3 → server2 → server1
 8. Phase 2  — networking     server3 → server2 → server1   ← console open
 9. Phase 5  — database       server2
10. Phase 4  — platform       server1
11. create the superuser, by hand
12. Phase 7  — monitoring     all
13. Phase 10 — backup         server3, then the pull key, then again
14. Phase 9  — cloudflare     server1   ← last: it exposes the platform
15. before the competition: audit_immutable + users_ssh_exclusive, then reboot
```

**Database before platform.** Django's migrations need somewhere to run, and a
migration that fails halfway leaves a partially migrated schema.

**Cloudflare last.** It puts the platform on the internet. Do that only once
everything behind it is working and verified — not as a way of testing whether
it is.

**Backup takes two passes.** The first run generates the pull key and prints it;
paste it into `users_backup_pull_key`, run
`bootstrap.yml --tags backup-key` to install it on server1 and server2, then run
the backup again.

**Run every phase twice.** The second run must report **zero changed tasks**.
That is the pass criterion for the whole repository — a run that keeps changing
things is not describing the system, it is fighting it.

**server1 last within each phase.** It is the host you most need reachable.

---

## 11. Verifying

Each step rules out one layer.

```bash
# 1. gunicorn alone, as nginx's user. Fails = socket permissions.
sudo -u www-data curl --unix-socket /run/gunicorn/gunicorn.sock http://localhost/healthz/

# 2. the whole stack, on the LAN
curl -k https://platform.jengasec.local/healthz/     # {"status":"ok","database":"ok"}

# 3. static is actually served
curl -kI https://platform.jengasec.local/static/css/variables.css

# 4. rate limiting engages — expect 200s then 429
for i in $(seq 1 15); do curl -ks -o /dev/null -w "%{http_code} "     https://platform.jengasec.local/login/; done

# 5. the database is closed to everyone but server1
psql "host=10.0.0.12 dbname=jengasec user=jengasec" -c 'SELECT 1;'

# 6. every monitoring target is up
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
```

Step 5 must **succeed from server1 and fail from anywhere else**.

### The tunnel

From **off campus** — a phone on mobile data is the honest test:

```bash
curl -I https://platform.jengasec.example/healthz/
```

Then confirm the origin is *not* directly reachable, which is the entire point:

```bash
curl --connect-timeout 5 https://<server1-public-address>/     # must time out
```

And open `/admin/` in a **logged-out browser**. You should meet Cloudflare's
identity check before Django's login form. A policy that excludes the organisers
locks them out of scoring, and the fix is in Cloudflare's dashboard — not
somewhere Ansible can reach while everyone is waiting.

### The backups

Do this **once, by hand, before the competition**. Everything else in that role
is machinery around this one question:

```bash
sudo -u backup /usr/local/sbin/jengasec-backup
sudo -u backup /usr/local/sbin/jengasec-backup-verify
jengasec-restore --list
systemctl list-timers jengasec-backup.timer
```

**A backup that has never been restored is a hope, not a backup.**

---

## 12. What to watch

Nothing is stubbed. What remains is operational.

| Watch | Why |
|---|---|
| **Restore verification actually runs** | It needs the GPG private key, which is deliberately not on server3. The monthly timer will fail its decrypt step until you run it from a machine that holds the key. Decide how you will handle that. |
| **The GPG private key is reachable by more than one person** | A backup only one graduating student can decrypt is a backup the club loses. |
| **MinIO updates, if you enable it** | A pinned `.deb`. Nothing will tell you when a security release lands. |
| **`nginx_hsts_enabled` before the event** | Turn it on once HTTPS is confirmed from a real browser. There is no server-side undo. |
| **`audit_immutable` and `users_ssh_exclusive`** | Both wanted on before the competition; both need a follow-up (a reboot, and every member's key committed). |
| **`logging_remote_enabled`** | Off. Logs on a compromised host are evidence an attacker can edit — worth turning on if a collector exists. |
| **Cloudflare Access membership** | Add and remove organisers as the team changes. An ex-member with an Access grant still reaches the admin login. |

### Optional, and honestly optional

`storage`, `minio` and `loadbalancer` are implemented and off. Each solves a
problem three servers and one web host may never have. Leaving them off is not
a gap — turning one on without needing it is the mistake.
