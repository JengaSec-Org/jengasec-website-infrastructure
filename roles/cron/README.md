# `cron`

**Phase 7 · NOT YET IMPLEMENTED**

Scheduled maintenance jobs.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Backup schedules
- Certificate renewal checks
- Log and temp-file cleanup
- Report generation
- Every job logs, and a silent failure must be impossible

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `cron_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `cron_jobs` | `[]` | list of dicts: name, minute, hour, user, job |
| `cron_mailto` | `"sucybersec@strathmore.edu"` | failures must reach a human |
| `cron_path` | `"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"` | — |

## Example play

```yaml
- name: Configure cron
  hosts: infra
  become: true
  roles:
    - role: cron
      tags: [cron]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `cron_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
