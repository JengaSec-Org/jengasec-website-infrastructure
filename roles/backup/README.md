# `backup`

**Phase 10 · NOT YET IMPLEMENTED**

Backups of the database, media, and configuration, with verified restores.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- pg_dump of the application database on a schedule
- rsync of app_media_dir and /etc
- Compression and GPG encryption before the data leaves the host
- Retention: daily, weekly, monthly tiers
- Restore procedure, scripted rather than remembered
- Automated restore verification into a scratch database

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `backup_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `backup_root` | `"/srv/backup"` | — |
| `backup_schedule` | `"0 2 * * *"` | 02:00 daily, outside competition hours |
| `backup_retention_daily` | `7` | — |
| `backup_retention_weekly` | `4` | — |
| `backup_retention_monthly` | `6` | — |
| `backup_compression` | `gzip` | — |
| `backup_encrypt` | `true` | backups contain submissions and judge scores |
| `backup_sources` | `[]` | list of dicts: name, host, type, path or database |
| `backup_verify_enabled` | `true` | an unrestored backup is a hope, not a backup |

## Example play

```yaml
- name: Configure backup
  hosts: infra
  become: true
  roles:
    - role: backup
      tags: [backup]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `backup_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
