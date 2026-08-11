# `postgresql`

**Phase 5 · Implemented**

PostgreSQL 15 — server, tuning, authentication, databases and roles.

This holds every submission, score, and judge override. Two things follow: it
must not be reachable from the LAN, and this role must never casually restart
it.

## Tuning is a fraction of RAM, not a number

Every memory setting is a proportion of the host's memory. If PostgreSQL moves
to a different machine, **recalculate** rather than copying these across.

| Setting | Value (4 GB host) | Fraction | Note |
|---|---|---|---|
| `shared_buffers` | 1 GB | ~25% | Higher rarely helps — PostgreSQL leans on the OS page cache, and a bigger value caches the same pages twice |
| `effective_cache_size` | 3 GB | ~75% | **Allocates nothing.** Only tells the planner how much cache to assume |
| `work_mem` | 8 MB | — | **Per sort, not per connection.** Three sorts × 100 connections = 300× this |
| `maintenance_work_mem` | 128 MB | — | VACUUM and CREATE INDEX; few run at once |

`max_connections` is 100. Raising it is almost never the fix for "too many
connections" — pooling is. On a 4 GB box, each connection is a process with its
own memory, so a bigger number trades stability for a bigger error message.

## pg_hba.conf ordering

PostgreSQL uses the **first** line that matches, then stops. It does not keep
looking for a better match and it does not warn you — so a broad rule above a
narrow one silently disables the narrow one.

The template emits most-specific-first for exactly that reason, and there is no
catch-all at the bottom. A host that has not been added explicitly gets:

```
FATAL: no pg_hba.conf entry for host "10.0.0.x", user "...", database "..."
```

That message is unambiguous, which is why no friendlier catch-all exists.

## Reload vs restart

Two handlers, because the difference matters on a live database.

**Reload** — everything in `pg_hba.conf` and most of `postgresql.conf`. Open
connections untouched.

**Restart** — only for settings read at startup: `shared_preload_libraries`,
`shared_buffers`, `max_connections`. This **drops every connection**.

`shared_preload_libraries` is the trap. A reload silently does not apply it, and
`CREATE EXTENSION pg_stat_statements` then fails with an error that never
mentions restarting. The role compares the live value against the desired one
and queues a restart only when they genuinely differ.

## The schema grant

Since PostgreSQL 15 the `public` schema is no longer writable by every role by
default. Without an explicit `CREATE, USAGE` grant, `manage.py migrate` fails on
a fresh database with a permission error that reads like a connection problem.

The role grants it to each database owner. Worth knowing, because it is a
recent change and most tutorials predate it.

## Safety

**It refuses to listen on `0.0.0.0`.** On a competition network that would
expose the scoring database to every participant. The assert runs before
anything is installed, and the role reads back the live listening address at the
end in case someone hand-edited since the last run.

`scram-sha-256`, never `md5` — PostgreSQL's md5 is effectively unsalted and
falls to offline cracking quickly.

## Variables

Full list in [`defaults/main.yml`](defaults/main.yml); production values in
`group_vars/database/main.yml`.

| Variable | Default | Notes |
|---|---|---|
| `postgresql_version` | `15` | What Debian 12 ships |
| `postgresql_listen_addresses` | `localhost` | Widened to the private address in `group_vars` |
| `postgresql_max_connections` | `100` | |
| `postgresql_shared_buffers` | `256MB` | `1GB` in production |
| `postgresql_databases` / `_users` | `[]` | Lists of dicts |
| `postgresql_hba_entries` | `[]` | **Order matters** |
| `postgresql_extensions` | `[pg_stat_statements]` | Needs the restart above |
| `postgresql_archive_mode` | `false` | Do not enable until `backup` drains the archive |
| `postgresql_replication_enabled` | `false` | Phase 6 |

## Do not enable WAL archiving yet

`postgresql_archive_mode` is off, and should stay off until the `backup` role
exists. PostgreSQL retains every WAL segment it could not archive — point it at
a directory nothing drains and the disk fills, at which point the database stops
accepting writes.

## Tags

`postgresql`, `packages`, `service`, `config`, `roles`, `databases`,
`extensions`, `verify`

## Verifying

```bash
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -c "SELECT name, setting, source FROM pg_settings
                          WHERE name IN ('shared_buffers','work_mem','max_connections');"
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules;"
sudo ss -tlnp | grep 5432
```

The last one must show the private address or localhost — **never `0.0.0.0`**.

From the web host, prove the application can actually connect:

```bash
psql "host=10.0.0.12 dbname=jengasec user=jengasec sslmode=prefer" -c "SELECT 1;"
```

From any other host, the same command must fail. If it succeeds, the firewall
rule in `group_vars/database/main.yml` is not doing its job.
