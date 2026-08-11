# `gunicorn`

**Phase 4 · NOT YET IMPLEMENTED**

WSGI application server running the Django project under systemd.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Install gunicorn into the application virtualenv
- Render the systemd unit and socket unit
- Worker count, class, and timeout tuning
- Unix socket ownership shared with the nginx user
- Log destinations under app_log_dir
- Graceful reload on deployment

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `gunicorn_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `gunicorn_workers` | `"{{ (ansible_processor_vcpus | int * 2) + 1 }}"` | the (2 x cores) + 1 convention |
| `gunicorn_worker_class` | `sync` | async only helps if the workload becomes IO-bound |
| `gunicorn_timeout` | `120` | Ollama evaluation calls are slow |
| `gunicorn_graceful_timeout` | `30` | — |
| `gunicorn_max_requests` | `1000` | recycle workers to bound memory growth |
| `gunicorn_max_requests_jitter` | `50` | stagger restarts so they never align |
| `gunicorn_bind` | `"unix:/run/gunicorn/gunicorn.sock"` | — |
| `gunicorn_log_level` | `info` | — |

## Example play

```yaml
- name: Configure gunicorn
  hosts: web
  become: true
  roles:
    - role: gunicorn
      tags: [gunicorn]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `gunicorn_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
