# `logging`

**Phase 7 · NOT YET IMPLEMENTED**

Journal retention, logrotate, and syslog forwarding.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Cap journald size and retention
- Logrotate policies for nginx, gunicorn, and PostgreSQL
- Forward to a central collector (Loki, Graylog, or ELK) later
- Keep audit logs on a separate rotation from application logs

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `logging_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `logging_journald_max_use` | `"500M"` | an uncapped journal fills the disk |
| `logging_journald_max_retention` | `"30day"` | — |
| `logging_logrotate_frequency` | `daily` | — |
| `logging_logrotate_rotate` | `14` | — |
| `logging_logrotate_compress` | `true` | — |
| `logging_remote_enabled` | `false` | — |
| `logging_remote_host` | `""` | — |

## Example play

```yaml
- name: Configure logging
  hosts: infra
  become: true
  roles:
    - role: logging
      tags: [logging]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `logging_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
