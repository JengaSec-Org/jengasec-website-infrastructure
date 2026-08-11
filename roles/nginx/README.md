# `nginx`

**Phase 4 · Implemented**

nginx does three jobs on this platform, and the third is easy to overlook:

1. **TLS terminator and reverse proxy**
2. **Load balancer** across the gunicorn backends
3. **The only thing serving static and media files**

## nginx *is* the load balancer

There is no separate HAProxy tier. Django traffic is balanced here, by the
upstream block:

```yaml
nginx_upstream_servers:
  - server: "unix:/run/gunicorn/gunicorn.sock"    # today: one local gunicorn
  # - server: "10.0.0.14:8000"
  #   weight: 1
  #   max_fails: 3
  #   fail_timeout: "30s"
```

Adding a web host is an edit to that list.

**`least_conn`, not round-robin.** Request durations here are wildly uneven — a
page view takes milliseconds, an AI evaluation takes a minute. Round-robin would
keep handing new work to a backend already busy with a long request.

**Health checks are passive.** After `max_fails` failures within
`fail_timeout`, nginx stops using that backend, then retries. nginx open source
has **no active health checking** — it never probes an idle backend, it only
learns from real requests failing. So the first request after a backend dies is
the one that discovers it. Worth knowing rather than assuming.

**Upstream keepalive needs three things, not one.** `keepalive 32` in the
upstream does nothing without `proxy_http_version 1.1` and
`proxy_set_header Connection ""`. Both are in the proxy snippet. Setting only
the first is a common mistake — it looks configured, and every request still
pays a fresh connection setup.

**Sticky sessions are off.** `ip_hash` *replaces* `least_conn`, so balancing
gets worse, and everyone behind one NAT address lands on a single backend. Only
meaningful with several backends, and the better fix is shared sessions — which
Django already has. The role warns if you enable it with one backend.

The `loadbalancer` role is a *separate* HAProxy tier for when you outgrow one
nginx. You almost certainly do not need it.

## Static and media are not optional

`whitenoise` is in the platform's `requirements.txt` but **not in `MIDDLEWARE`**,
and `config/urls.py` serves media only when `DEBUG` is true. With `DEBUG=False`
Django serves **neither**.

Without these location blocks the site renders unstyled and every uploaded
document 404s.

| Location | From | Cache | Note |
|---|---|---|---|
| `/static/` | `staticfiles/` | 30d immutable | Hashed filenames, so long expiry is safe |
| `/media/` | `media/` | `no-cache` | Submissions. A cached old version being marked is the worst outcome |

### Media is served as an attachment

`Content-Disposition: attachment`, always.

An uploaded SVG or HTML file **rendered** in the browser executes script in this
origin. On a platform where competitors upload files that judges open, that is a
direct route to stealing a judge's session and rewriting scores. Forcing
download is the cheap, complete fix.

## The `add_header` trap

`add_header` **does not inherit** into a location that has its own
`add_header`. Set headers at server level and they apply — until some location
adds one of its own, at which point that location silently loses **all** of
them.

That is why the security headers are a snippet, and why `/static/` and `/media/`
include it again after their own `add_header` lines.

## HSTS is off

There is **no server-side undo**. Once a browser has seen the header it refuses
plain HTTP to this host for `max-age`, even if you remove the header. Ship it
with a broken certificate and that user cannot reach the site for a year.

Turn `nginx_hsts_enabled` on only after confirming HTTPS works from a real
browser.

## CSP is report-only

A CSP that breaks the application is worse than none. `'unsafe-inline'` is
present because the platform's templates carry inline scripts and styles —
removing it is real work, and it belongs in the platform repository.

Watch the browser console on the Chart.js dashboards before enforcing.

## Rate limiting

| Zone | Rate | Applied to |
|---|---|---|
| `jengasec_login` | 5/min, burst 5 | `/login/`, `/admin/` |
| `jengasec_general` | 30/s, burst 50 | everything else |
| `jengasec_conn` | 20 concurrent | per address — blunts slow-loris |

Returns **429**, not the default 503: 503 says "server broken", 429 says "you
are going too fast", and only one is true. Pairs with the `nginx-limit-req`
fail2ban jail that already exists.

## Timeouts must agree with gunicorn

`nginx_proxy_read_timeout` (180s) must exceed `gunicorn_timeout` (120s), or
nginx gives up first and the user sees a 504 while the worker is still doing
useful work. **The role asserts this** rather than trusting it.

## Variables

Full list in [`defaults/main.yml`](defaults/main.yml).

| Variable | Default |
|---|---|
| `nginx_upstream_servers` | one local gunicorn socket |
| `nginx_upstream_method` | `least_conn` |
| `nginx_upstream_keepalive` | `32` |
| `nginx_sticky_sessions` | `false` |
| `nginx_ssl_certificate` | `<host>-fullchain.crt` |
| `nginx_hsts_enabled` | `false` |
| `nginx_csp_report_only` | `true` |
| `nginx_rate_limit_login` | `5r/m` |
| `nginx_client_max_body_size` | `25m` |
| `nginx_media_force_download` | `true` |
| `nginx_proxy_read_timeout` | `180` |

## Tags

`nginx`, `packages`, `config`, `headers`, `site`, `tls`, `service`, `verify`

## Verifying

```bash
sudo nginx -t
sudo systemctl status nginx
curl -kI https://platform.jengasec.local/
curl -k https://platform.jengasec.local/healthz/
curl -kI https://platform.jengasec.local/static/css/variables.css
```

Confirm the security headers survived into a location that sets its own:

```bash
curl -kI https://platform.jengasec.local/static/css/variables.css | grep -i x-content-type
```

Check rate limiting actually engages:

```bash
for i in $(seq 1 15); do curl -ks -o /dev/null -w "%{http_code} " \
    https://platform.jengasec.local/login/; done
```

You should see `200` a few times and then `429`.

## If you get a 502

nginx cannot reach gunicorn. Almost always the socket permissions:

```bash
ls -l /run/gunicorn/gunicorn.sock       # want: srw-rw---- jengasec www-data
sudo tail /var/log/nginx/jengasec-error.log
sudo -u www-data curl --unix-socket /run/gunicorn/gunicorn.sock http://localhost/
```

The evidence is in **nginx's** log, not gunicorn's — which is what sends people
debugging the wrong service.

**503** means every upstream backend is marked failed.
