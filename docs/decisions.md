# Decisions

Why the infrastructure looks like this. Each entry records the reasoning and,
where relevant, what would change our mind — a decision without a reversal
condition is a preference wearing a costume.

---

## No Docker, no Kubernetes

**Native systemd deployment: nginx + gunicorn + PostgreSQL + Redis.**

The servers have 8 GB and 4 GB of RAM. A container runtime costs memory and,
more importantly, debugging effort — during a competition, "why is the container
not starting" is a worse problem to have at 2am than "why is the service not
starting", because there is an extra layer between you and the answer.

systemd already provides what people usually reach for containers to get:
supervision, restart policy with backoff, dependency ordering, resource limits,
journal logging, and a sandbox. Kubernetes on three servers of this size is
overhead in search of a problem.

The platform README lists "Docker + Gunicorn + Nginx (planned)". This repository
takes the other path deliberately. Note that the competition *itself* involves
Docker — blue teams ship systems as Docker images, red teams attack dockerized
replicas — but that is workload, not infrastructure, and it belongs on the cyber
range rather than under the platform.

What systemd gives us in practice, visible in the `gunicorn` and `redis` roles:
`ProtectSystem=strict` with an explicit `ReadWritePaths`, an empty
`CapabilityBoundingSet`, a syscall filter, `MemoryMax`, and socket activation
that queues requests during a reload. That is most of what people reach for a
container to get.

**Reconsider if:** the club moves to cloud hosting, needs to run more than one
application per host, or grows past what one person can deploy by hand.

---

## Python 3.11, not 3.12

Debian 12 ships Python 3.11. The platform README asks for 3.12+, but that is a
preference rather than a requirement: Django 5.0 and 5.1 both support 3.11, and
every package in `requirements.txt` — psycopg2-binary, PyMuPDF, pdfplumber,
reportlab, pandas, gunicorn, whitenoise — has a 3.11 wheel.

Building Python from source means owning its security updates by hand, forever.
Debian will not patch it for you. That is a poor trade for a version number.

The `python` role has the source-build tasks written and disabled behind
`python_build_from_source`, using `make altinstall` so it can never shadow the
system interpreter — apt is written in Python, and recovering a server whose
system Python was replaced is genuinely unpleasant.

**Reconsider if:** a dependency genuinely requires 3.12. Then it is one variable.

---

## UFW, not nftables

Both were on the table. UFW won on two grounds:

1. **Fewer ways to lock yourself out.** The firewall role already carries three
   layers of protection against that; nftables would need more, and the failure
   mode is the same either way — a server nobody can reach.
2. **The Ansible module is mature.** `community.general.ufw` handles rule
   idempotence correctly, which matters for the "second run reports zero
   changes" rule this repository is built around.

The usual argument for nftables — that students see the real ruleset rather than
a wrapper — is answered by keeping the ruleset as **data** in `group_vars`. The
rules are readable in one place, and `iptables -L -n -v` still shows what UFW
generated for anyone who wants to look underneath.

**Reconsider if:** you need rules UFW cannot express — connection tracking
tricks, NAT for the cyber range, or per-interface policies.

---

## The ruleset is data, not code

Firewall rules, DNS records, DHCP reservations, and service accounts are all
lists of dicts in `group_vars`, looped over in tasks and templates.

Adding a DNS record or opening a port is then a data edit that a club member can
make and review without reading any Ansible. It also means a code review of a
change shows the actual intent — `port: 5432 from: 10.0.0.11` — rather than a
diff in a task file.

---

## nginx is the load balancer, not HAProxy

Django traffic is balanced by nginx's own upstream block — `least_conn` across
`nginx_upstream_servers`, passive health checks, upstream keepalive. Adding a
second application host is an edit to that list.

`least_conn` rather than round-robin because request durations here are wildly
uneven: a page view takes milliseconds, an AI evaluation takes a minute.
Round-robin would keep handing new work to a backend already busy with a long
request.

The `loadbalancer` role still exists, re-scoped to a **dedicated HAProxy tier in
front of several nginx hosts** — the layer you add after outgrowing one nginx.
It is disabled, and it refuses to run on a host in the `web` group because both
want ports 80 and 443.

The one thing that tier would buy: **active** health checks. nginx open source
only has passive ones — it never probes an idle backend, it learns from real
requests failing. Not worth a whole extra service until there is more than one
nginx to check.

**Reconsider if:** you add a second web host *and* want a backend's failure
detected before a user hits it.

---

## nginx serves static and media — this is required, not an optimisation

An earlier version of this document called it an optimisation, on the grounds
that WhiteNoise is in the platform's `requirements.txt`. **That was wrong.**

WhiteNoise is installed but **not in `MIDDLEWARE`** (`config/settings.py`), and
`config/urls.py` serves media only `if settings.DEBUG`. With `DEBUG=False`,
Django serves **neither** static nor media. Without nginx's location blocks the
site renders unstyled and every uploaded document 404s.

WhiteNoise is deliberately left unwired rather than enabled: nginx serving from
disk is faster, and having both would mean two things serving the same files
with different cache headers.

Media is served `Content-Disposition: attachment`, always. An uploaded SVG or
HTML file *rendered* in the browser executes script in the platform's origin —
on a system where competitors upload files that judges open, that is a direct
route to stealing a judge's session.

---

## The platform repository was changed too

Three settings that no amount of infrastructure could substitute for:

| Change | Why |
|---|---|
| `SECURE_PROXY_SSL_HEADER` | Behind nginx Django sees plain HTTP. Without this, `request.is_secure()` is false and secure cookies are never set |
| `CSRF_TRUSTED_ORIGINS` | Django 4+ rejects every login POST whose Origin is not listed — with an error that does not name the cause |
| `/healthz/` | Runs `SELECT 1`. The landing page at `/` touches no database and returns 200 with PostgreSQL down, so a health check against it creates false confidence |

`SECURE_SSL_REDIRECT` is deliberately **not** set: nginx already redirects, and
both together produce a redirect loop whenever the proxy header is
misconfigured — a failure the browser reports only as "too many redirects".

The `django` role asserts the checkout contains these settings and refuses to
deploy without them, so an old checkout fails the play rather than the login
page.

---

## A Cloudflare Tunnel, not an open port

The platform must be reachable off campus. The obvious way — open 443 and point
public DNS at server1 — was not taken.

`cloudflared` dials **out** to Cloudflare and holds the connection open.
Requests arrive down that existing connection, so no inbound port is involved at
all. Three things follow:

- The origin's address never appears in public DNS. There is nothing to scan.
- A campus firewall blocking inbound traffic stops being an obstacle, and you do
  not have to ask for an exception you would probably not get.
- Cloudflare's WAF and rate limiting sit in front, on the free tier.

So `group_vars/web` now restricts 443 to the competition LAN and closes 80
entirely. On-campus users reach nginx directly — faster, and it survives
Cloudflare being unreachable. Everyone else comes through the tunnel.

**Re-opening those rules to `any` would throw away the entire benefit.**

### The origin hop is still HTTPS

cloudflared connects to `https://127.0.0.1:443`, not plain HTTP, even though
both are on one host and nothing crosses a wire.

It reuses the certificate the `certificates` role already issues, avoids adding
a loopback-only HTTP listener with its own server block, and keeps the habit
right. `originServerName` must be the *internal* name, because that is what the
certificate is for.

### Split-horizon naming

`platform.jengasec.local` internally via Bind9, `platform.<public>` via the
tunnel. Both in `server_name`, `ALLOWED_HOSTS`, and `CSRF_TRUSTED_ORIGINS`.

`.local` cannot be used publicly — it is reserved for mDNS and Cloudflare will
not serve it. The role refuses a `.local` domain outright rather than letting it
fail obscurely at Cloudflare's end.

### Cloudflare Access on `/admin/`

An identity check at the edge, before a request reaches Django. `/admin/`
controls every score, and with the platform on the internet Django's login form
would otherwise be the only thing in front of it.

**Reconsider if:** the club moves to a network where inbound 443 is genuinely
available and a tunnel adds a dependency rather than removing one.

---

## Backups pull; they are not pushed

server3 reaches out to server1 and server2 and pulls. The source hosts have no
route into the backup host.

**A compromised web host cannot delete its own backups.** With a push model it
can — and deleting the backups is the first thing ransomware does, before
anyone notices anything else is wrong.

The cost is an SSH path that has to be created deliberately: a forced-command
key (`command="rrsync -ro /"`, `restrict`, `from=<backup host>`) that can run one
read-only rsync and nothing else. Even stolen, it gets an attacker a read-only
file copy from one address.

Backups are encrypted to a **public** GPG key, so the backup host can write
archives it cannot read. Someone who compromises server3 — which is also the
monitoring host, and reachable from the LAN — gets ciphertext.

That creates one real tension, and it is documented rather than hidden:
**automated restore verification needs the private key, which deliberately is
not on that host.** Running the monthly verification by hand from a machine that
holds the key is the honest resolution.

---

## Two third-party APT repositories

Grafana and cloudflared. Both are absent from Debian, and for both the
alternative is worse: a pinned `.deb` means owning every security update by
hand, and an unpatched Grafana or an outdated tunnel daemon is worse than an
auto-updating one.

Each key goes to `/etc/apt/keyrings` — not the deprecated `apt-key`, where a key
can sign *any* repository — and each source is scoped with `signed-by=`, so it
can install that vendor's packages and nothing else.

| Source | Package | Avoidable? |
|---|---|---|
| `apt.grafana.com` | grafana | Yes — `grafana_enabled: false`; Prometheus has a usable UI |
| `pkg.cloudflare.com` | cloudflared | Only by not being reachable off campus |
| `pkgs.tailscale.com` | tailscale | Yes — `tailscale_enabled: false`; then the lab is admin-only from inside the rack |

**MinIO goes the other way** — no repository exists, so it is a pinned `.deb`
with a checksum, and its updates are manual. That is a genuine argument against
enabling it, and it is why the role is off: local disk plus nginx already works.

---

## Every managed file is a Jinja2 template

Not `copy`, not `lineinfile`. If Ansible owns a file, it renders the whole file.

`lineinfile` produces configurations that are the sum of many partial edits, and
after a few months nobody can say what the file should look like — only what was
last changed. A template is the single answer to "what is in this file and why".

**One deliberate exception:** `/etc/login.defs` in the `security` role. It
carries many distribution defaults that are correct and that we have no reason
to own, so seven specific keys are set with `lineinfile` and the rest is left to
Debian.

---

## `networking_configure` defaults to false

The role that reconfigures the interface you are connected over is off until you
turn it on.

If the servers already have working static addresses from the Debian installer,
leaving it off permanently is a reasonable choice. Ansible does not have to own
everything to be useful, and the interface configuration is the one place where
being wrong costs a trip to the server room.

---

## `dhcp_configure` defaults to false

Exactly one DHCP server may be authoritative on a broadcast domain. If the
campus network already runs one, deploying ours hands out conflicting leases to
every device on the segment — a network-wide outage caused by the club, which is
the kind of thing that ends a club's network access.

It is only appropriate on an isolated competition segment.

---

## Internal CA, not Let's Encrypt

`jengasec.local` is not delegated from the public root — `.local` is reserved
for mDNS. **No public CA will ever issue a certificate for it.** This is
structural, not a configuration choice.

So the default is a private CA whose key lives on one host and never moves. The
Let's Encrypt provider is implemented and waiting for a real domain.

Club laptops will show a certificate warning until the CA is installed on them.
That is the cost, and it is the honest one — the alternative is turning off
verification, which teaches exactly the wrong lesson at a cybersecurity club.

---

## Two audit trade-offs that go against the benchmark

Both are places where the strict CIS answer would take the competition platform
down mid-event:

| Setting | CIS | Ours | Reasoning |
|---|---|---|---|
| auditd buffer overflow (`-f`) | `2`, kernel panic | `1`, printk | A burst of audit events should not halt the server. The kernel log still records that events were lost. |
| `disk_full_action` | `halt` | `rotate` | A full disk becomes a total outage. We lose the oldest history instead. |

If this were a system of record rather than a competition platform, both would
go the other way. They are documented at the point where the choice is made, in
`roles/audit/defaults/main.yml`, rather than left as silent deviations.

---

## Compilers are not removed

CIS-style hardening recommends restricting compilers. The `common` role installs
`build-essential` anyway, because pip needs it to build psycopg2 and PyMuPDF
from source.

Removing compilers would break deployment. This is an honest, documented trade
rather than a silent gap.

**Reconsider if:** the club builds wheels on a separate machine and ships those
instead. Then `security_restrict_compilers` becomes worth turning on.

---

## IPv6 is disabled

Not because IPv6 is bad, but because a half-configured IPv6 stack is worse than
none. Every firewall rule in this repository is v4-only, so an unmanaged v6
address hands out reachability nobody intended and nobody thought to filter —
while everyone believes the host is protected.

`networking_ipv6_enabled` and `firewall_ipv6` must be turned on **together**.

---

## Roles are grouped by function, not by machine

The inventory has `web`, `database`, `dns`, `backup`, `monitoring` — not
`server1`, `server2`, `server3`.

Moving PostgreSQL to a different box is then an inventory edit rather than a
change to any role or playbook, and the same layout survives the club adding a
fourth server.

---

## Stubs fail loudly

The 14 unimplemented roles raise an error rather than doing nothing quietly.

A green Ansible run that changed nothing is the most expensive kind of bug in
infrastructure code: you believe a machine is configured when it is not, and you
find out during the event. Every stub says exactly what did not happen and where
to read about it.
