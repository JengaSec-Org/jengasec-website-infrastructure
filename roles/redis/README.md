# `redis`

**Phase 4 · Implemented**

Cache, session store, and future Celery broker.

## Treated as a cache, not a database

No persistence, a hard memory cap, an eviction policy. Losing the contents costs
a round of re-computation, not data. That framing justifies most of the
configuration:

| Setting | Value | Why |
|---|---|---|
| `save ""` | persistence off | RDB snapshots **fork the process**, briefly doubling memory — a real risk on a 4 GB host shared with PostgreSQL |
| `maxmemory` | 256 MB | Without a cap Redis grows until the OOM killer intervenes — and it usually picks PostgreSQL, because PostgreSQL is bigger |
| `maxmemory-policy` | `allkeys-lru` | `noeviction` returns errors on write instead, which for a session store means users randomly cannot log in |
| `stop-writes-on-bgsave-error` | `no` | The default halts writes on save failure. Correct for a database, wrong for a cache — it would take the site down over data we can regenerate |

If Celery task state moves in here, revisit all four: losing a queue
mid-competition is a different kind of problem from losing a cache.

## Why the guards are strict

An exposed Redis without a password is not a data leak — it is **remote code
execution**. `CONFIG SET dir`, `CONFIG SET dbfilename`, `SAVE`, and you have
written a file anywhere the redis user can write, `authorized_keys` included.

Three overlapping defences:

1. **The role refuses** to bind to a non-loopback address unless
   `redis_requirepass` is at least 16 characters, and refuses `0.0.0.0`
   outright.
2. **Dangerous commands are renamed** to an unguessable suffix derived from the
   password — `CONFIG`, `FLUSHALL`, `FLUSHDB`, `KEYS`, `SHUTDOWN`. Renamed
   rather than removed, so a deliberate invocation is still possible for whoever
   holds the config file.
3. **`ProtectSystem=strict`** in the systemd drop-in makes the filesystem
   read-only apart from Redis's own directories. Even with `CONFIG` available,
   there is nowhere useful to write.

`KEYS` is on the list for a different reason: Redis is single-threaded, so a
`KEYS *` on a large keyspace blocks every other client until it finishes.

## systemd hardening

Applied as a **drop-in**, not a replacement unit, so package upgrades keep
working. `NoNewPrivileges`, `ProtectSystem=strict`, an empty
`CapabilityBoundingSet`, a syscall filter, `MemoryDenyWriteExecute`, and a
`MemoryMax` at twice `maxmemory` as a second ceiling.

Most of what people reach for a container to get, without the container — see
[decisions.md](../../docs/decisions.md).

## Variables

| Variable | Default | Notes |
|---|---|---|
| `redis_bind` | `127.0.0.1` | Widened to the private address in `group_vars/database` |
| `redis_port` | `6379` | |
| `redis_requirepass` | `{{ vault_redis_password }}` | **Required** to bind non-locally |
| `redis_maxmemory` | `256mb` | |
| `redis_maxmemory_policy` | `allkeys-lru` | |
| `redis_save_enabled` | `false` | |
| `redis_appendonly` | `false` | |
| `redis_rename_dangerous_commands` | `true` | |
| `redis_systemd_hardening` | `true` | |

## Tags

`redis`, `packages`, `config`, `hardening`, `service`, `verify`

## Verifying

```bash
export REDISCLI_AUTH='<the vault password>'
redis-cli -h 10.0.0.12 ping
redis-cli -h 10.0.0.12 config get maxmemory
redis-cli -h 10.0.0.12 info memory
redis-cli -h 10.0.0.12 slowlog get 10
```

Use `REDISCLI_AUTH`, not `-a` — the `-a` flag puts the password in the process
list, where any local user can read it with `ps`.

`config get maxmemory` returning **0 means unlimited**, which is the setting
that lets Redis take PostgreSQL down with it. The role reports this at the end
of every run for that reason.

Confirm it is not reachable from anywhere it should not be:

```bash
# from server1 — should connect
nc -zv 10.0.0.12 6379
# from any other host — should time out
```
