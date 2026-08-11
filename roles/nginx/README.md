# `nginx`

**Phase 4 · NOT YET IMPLEMENTED**

Reverse proxy and TLS terminator in front of gunicorn.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Reverse proxy to the gunicorn socket
- TLS termination using the certificates role output
- Security headers (HSTS, CSP, X-Frame-Options, X-Content-Type-Options)
- Static file serving from app_static_dir
- Media file serving from app_media_dir, with execution disabled
- gzip compression and proxy caching
- Rate limiting on /login/ and /admin/
- Access and error logging, with logrotate

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `nginx_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `nginx_worker_processes` | `auto` | one worker per core |
| `nginx_worker_connections` | `1024` | — |
| `nginx_client_max_body_size` | `"25m"` | submission uploads are PDFs and DOCX |
| `nginx_keepalive_timeout` | `65` | — |
| `nginx_gzip_enabled` | `true` | — |
| `nginx_hsts_max_age` | `31536000` | one year, only once HTTPS is confirmed working |
| `nginx_rate_limit_login` | `"5r/m"` | brute-force ceiling on the login form |
| `nginx_server_name` | `"platform.{{ jengasec_domain }}"` | — |
| `nginx_upstream_socket` | `"unix:/run/gunicorn/gunicorn.sock"` | must match gunicorn_bind |

## Example play

```yaml
- name: Configure nginx
  hosts: web
  become: true
  roles:
    - role: nginx
      tags: [nginx]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `nginx_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
