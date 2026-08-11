# `postgresql`

**Phase 5 · NOT YET IMPLEMENTED**

PostgreSQL server, databases, roles, and connection policy.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Install PostgreSQL and the contrib packages
- Tune postgresql.conf for the available RAM
- Render pg_hba.conf from postgresql_hba_entries
- Create databases and roles from group_vars
- Install extensions
- Configure WAL archiving for point-in-time recovery
- Streaming replication (Phase 6)

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `postgresql_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `postgresql_version` | `15` | the version Debian 12 ships |
| `postgresql_listen_addresses` | `"localhost"` | widen only for a remote app host |
| `postgresql_port` | `5432` | — |
| `postgresql_max_connections` | `100` | — |
| `postgresql_shared_buffers` | `"256MB"` | roughly 25% of RAM |
| `postgresql_effective_cache_size` | `"768MB"` | roughly 50-75% of RAM |
| `postgresql_work_mem` | `"4MB"` | per sort operation, multiplied by connections |
| `postgresql_password_encryption` | `scram-sha-256` | never md5 |
| `postgresql_databases` | `[]` | — |
| `postgresql_users` | `[]` | — |
| `postgresql_hba_entries` | `[]` | — |
| `postgresql_extensions` | `["pg_stat_statements"]` | — |

## Example play

```yaml
- name: Configure postgresql
  hosts: infra
  become: true
  roles:
    - role: postgresql
      tags: [postgresql]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `postgresql_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
