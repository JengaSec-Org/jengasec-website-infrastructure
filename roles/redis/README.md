# `redis`

**Phase 4 · NOT YET IMPLEMENTED**

In-memory cache, session store, and future Celery broker.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Install and configure redis-server
- Bind to the private interface only, never 0.0.0.0
- requirepass authentication from the vault
- maxmemory cap and eviction policy
- Persistence policy (RDB vs AOF)
- systemd hardening of the unit

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `redis_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `redis_bind` | `"127.0.0.1"` | widen only for a remote application host |
| `redis_port` | `6379` | — |
| `redis_maxmemory` | `"256mb"` | hard cap; Redis must not starve PostgreSQL |
| `redis_maxmemory_policy` | `allkeys-lru` | cache semantics, evict coldest keys |
| `redis_appendonly` | `false` | a cache does not need durability |
| `redis_databases` | `16` | — |
| `redis_requirepass` | `"{{ vault_redis_password }}"` | — |

## Example play

```yaml
- name: Configure redis
  hosts: web
  become: true
  roles:
    - role: redis
      tags: [redis]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `redis_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
