# `gunicorn`

**Phase 4 · Implemented**

The WSGI server running Django, under systemd.

This role owns the **units, the socket, and the tuning** — not the package.
gunicorn is in the platform's `requirements.txt`, so the `django` role installs
it into the virtualenv along with everything else.

## A socket unit *and* a service unit

Not just a service. systemd creates and owns the socket, then hands the
listening file descriptor to gunicorn. Two consequences, both worth having:

1. **The socket exists with correct ownership before gunicorn starts**, so nginx
   never races a half-started application.
2. **A request arriving during a restart is queued by the kernel**, not refused.
   A deployment becomes a pause rather than an error page.

Enable the **socket**, not the service. Enabling both starts gunicorn twice on
boot and produces a confusing "address in use".

## The 502 you will otherwise spend an hour on

The socket is owned `jengasec:www-data`, mode `0660`. **Group-writable is
required** — nginx runs as `www-data` and must be able to write to it.

Get it wrong and every request returns 502, the error appears only in *nginx's*
log as "permission denied", and gunicorn's own log shows nothing at all. That
combination sends people debugging the wrong service. The role reports the
socket's owner and mode at the end of every run for exactly this reason.

## Timeouts must agree with nginx

`gunicorn_timeout` (120s) must stay **below** nginx's `proxy_read_timeout`. If
nginx gives up first, the user sees a 504 while the worker is still doing useful
work, and the request completes into a connection nobody is listening to.

120s is generous because document parsing (PyMuPDF, pdfplumber) and Ollama calls
are genuinely slow.

## Workers

`(2 × cores) + 1`, capped at 9. Each worker is a full Python process holding its
own copy of Django — on an 8 GB box more workers is not automatically better.

`sync` worker class, which is right while the workload is CPU- and
database-bound. `gevent` only helps when requests spend their time waiting on
IO. The Ollama calls do exactly that, so if AI evaluation moves into the request
path, revisit — though the better answer is to move it out of the request path.

**Worker recycling** is on: `max_requests 1000` with `jitter 50`. A blunt but
effective guard against slow memory growth in a long-running Python process.
Without the jitter every worker hits the limit at the same request count and
they all restart together, which is a brief outage rather than a rolling one.

## Reload, not restart, for deployments

`ExecReload=/bin/kill -s HUP $MAINPID`. gunicorn re-execs its workers while
holding the socket open, so nothing in flight is dropped. The `django` and
`deployment` roles notify **reload gunicorn**, not restart.

## Logging

To the journal — `journalctl -u gunicorn` is the one place to look, and the
journal is already size-capped by the `os` role.

Gunicorn's access log is **off**. nginx is the real access log and records the
actual client address; gunicorn's would only ever show `127.0.0.1`, which is
duplicate volume for no information.

## Sandboxing

`ProtectSystem=strict` with an explicit `ReadWritePaths` — the application can
write uploads and logs, but **the code directory stays read-only**, so a
compromise cannot rewrite the application.

`MemoryDenyWriteExecute` is deliberately **not** set: CPython's ctypes and some
compiled extensions need writable-executable pages, and enabling it breaks the
application in ways that are hard to trace back to that one line.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `gunicorn_workers` | `(2 × vcpus) + 1`, max 9 | |
| `gunicorn_worker_class` | `sync` | |
| `gunicorn_timeout` | `120` | Must be **below** nginx's `proxy_read_timeout` |
| `gunicorn_max_requests` | `1000` | Recycle workers |
| `gunicorn_max_requests_jitter` | `50` | Stagger the recycles |
| `gunicorn_bind` | `unix:/run/gunicorn/gunicorn.sock` | Must match `nginx_upstream_servers` |
| `gunicorn_socket_group` | `www-data` | nginx's user |
| `gunicorn_enable_access_log` | `false` | nginx has the real one |
| `gunicorn_systemd_hardening` | `true` | |

## Tags

`gunicorn`, `directories`, `units`, `service`, `verify`

## Verifying

```bash
systemctl status gunicorn.socket gunicorn
ls -l /run/gunicorn/gunicorn.sock        # must be srw-rw---- jengasec www-data
journalctl -u gunicorn -n 50
sudo -u www-data curl --unix-socket /run/gunicorn/gunicorn.sock http://localhost/
```

That last command is the useful one: it talks to gunicorn **as nginx's user**,
bypassing nginx entirely. If it works and the site does not, the problem is in
nginx. If it fails with a permission error, it is the socket group.
