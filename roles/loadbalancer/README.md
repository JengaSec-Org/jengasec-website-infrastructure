# `loadbalancer`

**Phase 6 · Implemented, disabled by default**

HAProxy as a dedicated load balancing tier.

> ## You probably do not need this role
>
> **nginx already load balances Django traffic.** See `nginx_upstream_servers`
> in the [`nginx`](../nginx/README.md) role — adding a second application host
> is an edit to that list, not a reason to deploy HAProxy.
>
> This role is for a dedicated tier in front of **several nginx hosts** — the
> layer you add after outgrowing one nginx, which with three servers and one web
> host is a long way off.

## Where the boundary is

| Layer | Balances across | Owned by |
|---|---|---|
| HAProxy *(this role, off)* | nginx hosts | `/etc/haproxy` |
| **nginx** *(active)* | gunicorn backends | `/etc/nginx` |
| gunicorn | its own workers | systemd |

One owner per file, so the two never fight.

## What it would buy you

**Active health checks.** nginx open source only has *passive* ones — it never
probes an idle backend, it learns from real requests failing, so the first
request after a backend dies is the one that discovers it. HAProxy probes on a
timer.

That is the main reason to add this tier, and it is not worth a whole extra
service until there is more than one nginx to check.

**Cookie-based affinity.** `loadbalancer_sticky_sessions` uses a cookie, not
source-address hashing. Correct where nginx's `ip_hash` is not: a cookie
identifies a *browser*, so an entire campus behind one NAT address is still
spread across backends.

## The health check must be `/healthz/`

`/healthz/` runs `SELECT 1` and returns 200 or 503, so a backend whose database
is unreachable is taken out of rotation.

Checking `/` would not do that — it is a `TemplateView` touching no database and
returns 200 with PostgreSQL completely down. The load balancer would keep
routing traffic to a backend that cannot serve a single real page.

## Timeouts stack outward

Each layer must be **more patient** than the one behind it:

```
haproxy 200s  >  nginx 180s  >  gunicorn 120s
```

Get this backwards and the outer layer gives up on work still in progress — the
user sees an error for a request that was about to succeed.

## Guards

**It refuses to run on a host in the `web` group.** Both HAProxy and nginx want
ports 80 and 443; whichever starts second fails to bind, and the error is a
systemd message that does not mention the other service. A dedicated load
balancer belongs on its own host.

It also refuses to start with an empty backend list, and warns if the stats page
has no password.

## The stats page

Shows every backend's health, current sessions, and error counts. Genuinely
useful — and a complete map of the infrastructure to anyone who reaches it.

Bound to the private address, and `stats admin` (which allows draining a backend
from the browser) is only enabled when a password is set.

Add `vault_haproxy_stats_password` to your vault before enabling this.

## Enabling it

You would need a fourth server, and:

```yaml
# host_vars/lb1.yml
loadbalancer_enabled: true
loadbalancer_backends:
  - { name: web1, address: "10.0.0.11", port: 443 }
  - { name: web2, address: "10.0.0.14", port: 443 }
```

Then point DNS at the load balancer rather than at server1.

## Variables

| Variable | Default |
|---|---|
| `loadbalancer_enabled` | `false` |
| `loadbalancer_backends` | `[]` |
| `loadbalancer_algorithm` | `leastconn` |
| `loadbalancer_health_check_path` | `/healthz/` |
| `loadbalancer_health_check_interval` | `5s` |
| `loadbalancer_sticky_sessions` | `true` |
| `loadbalancer_timeout_server` | `200s` |
| `loadbalancer_stats_enabled` | `true` |

## Tags

`loadbalancer`, `packages`, `tls`, `config`, `service`, `verify`

## Verifying

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18
sudo systemctl status haproxy
```

Then open `http://<lb-host>:8404/haproxy-stats`.

Drain a backend for maintenance without a config change:

```bash
echo "set server jengasec_web/web1 state drain" | sudo socat stdio /run/haproxy/admin.sock
```

Existing sessions finish; no new ones are sent. `state ready` puts it back.

## Note on the certificate

HAProxy wants the certificate and private key concatenated in **one** file,
unlike nginx which takes them separately. The role builds that file rather than
asking the `certificates` role to produce a HAProxy-shaped artefact — which
keeps that role format-agnostic.
