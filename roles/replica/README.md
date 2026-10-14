# `replica`

Keeps a live, read-only copy of the website's database on the database VM
(`192.168.40.45`), using PostgreSQL logical replication from Neon.

```
  Render (public)          web VM 192.168.40.11
        │                          │
        └──── read + write ────────┤
                    ▼              │   (this role runs here)
             Neon  (PRIMARY)       │
                    │
        logical replication — one way, continuous
                    ▼
     192.168.40.45 : jengasec_web   (read-only copy)
```

## Why one way

Both websites write to **Neon only**. Two writable copies that sync each other
fail the first time two people register at the same moment: both copies hand
out the same id, replication stops on the conflict, and one registration is
lost. Neon is the only copy both sites can reach — Render cannot reach the lab
— so Neon is the primary and the database VM follows it.

The copy is for reading, for a backup inside the lab, and as the starting point
of a future read-only fallback. **Never write to it**: the first write that
collides with an incoming row stops replication.

It is a separate database from the API's on the same server. The role never
touches anything else there, and the sync job refuses to drop any database it
did not create itself (it checks the database's comment).

## What it does

Installs `jengasec-replica-sync` and a systemd timer that runs it every ten
minutes. Each run:

1. Points the Neon publication at every current table.
2. Compares the table/column layout of Neon and the copy.
3. If they differ — or the subscription or its slot is missing — drops the
   copy and rebuilds it: schema with `pg_dump`, rows from the subscription's
   initial copy. The data is small, so this takes seconds.
4. Fails unless the apply worker is running.

Why rebuild on every schema change: logical replication copies rows, never
`ALTER TABLE`. Render runs migrations on Neon on every push to `main`, outside
Ansible; after one that changes a table, the copy stops applying changes until
its schema matches. The timer is what notices.

## Before switching it on

**In Neon** (whoever owns the project):

- Project settings → **Logical Replication → Enable**. It restarts the compute
  briefly, and cannot be switched off again without dropping all slots.
- The URL the website uses must belong to the role that owns the tables
  (`neondb_owner` — migrations created them). The role turns Neon's pooled URL
  into the direct one automatically; replication cannot use the pooler.

**On the database VM** (whoever administers `192.168.40.45`):

- A login allowed to create databases and subscriptions — superuser, or on
  PostgreSQL 16+ `CREATEDB` + `pg_create_subscription` + membership in the
  `jengasec_web` role. Into the vault as `vault_replica_admin_user` /
  `vault_replica_admin_password`.
- `pg_hba.conf` entries for `192.168.40.11` for that login (database
  `postgres`) and for `jengasec_web` (database `jengasec_web`).
- Free logical replication workers: one for the subscription, plus one per
  table during the initial copy. The defaults (`max_logical_replication_workers
  = 4`, `max_worker_processes = 8`) are enough unless the API also subscribes
  to something.
- Outbound internet to Neon on 5432 — the subscription connects *from* this
  server to Neon.

**In the vault:** `vault_jengasec_db_url` (already there for the website),
`vault_replica_admin_user`, `vault_replica_admin_password`,
`vault_replica_owner_password`.

Then set `replica_enabled: true` and run:

```bash
make replica INVENTORY=inventories/v1
```

## Checking it

```bash
sudo systemctl start jengasec-replica-sync      # one run, now
journalctl -u jengasec-replica-sync -n 40       # "OK - N of N tables in sync"
systemctl list-timers jengasec-replica-sync     # next scheduled run
```

A quick proof end to end: change a team's name on the website, then on the
database VM:

```bash
psql -h 192.168.40.45 -U jengasec_web jengasec_web -c "SELECT team_name FROM accounts_team ORDER BY id DESC LIMIT 5;"
```

## Things to know

- **Neon storage.** A slot whose subscriber is unreachable keeps WAL on Neon
  until it reconnects. A long outage of the database VM therefore grows Neon's
  storage. If it will be off for days, drop the subscription (the next run
  rebuilds it).
- **Sequences are not replicated.** Fine for a read-only copy. A future
  failover that makes the copy writable must `setval` every sequence first.
- **Passwords.** The subscription's connection string, with the Neon password,
  is stored in the database VM's catalog, readable by its superusers. A
  dedicated Neon role with `REPLICATION` and `SELECT` only is the tidier
  answer; set `replica_source_url` to it when one exists.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `replica_enabled` | `false` | Switch on once the prerequisites exist |
| `replica_source_url` | `django_db_url`, pooler stripped | Neon, direct endpoint |
| `replica_host` / `_port` | `192.168.40.45` / `5432` | The database VM |
| `replica_admin_user` / `_password` | from vault | Creates databases and subscriptions |
| `replica_database` / `replica_owner` | `jengasec_web` | Separate from the API's database |
| `replica_excluded_tables` | `[]` | Tables not copied |
| `replica_pg_client_version` | `17` | Must be ≥ Neon's major version |
| `replica_sync_schedule` | `*:0/10` | systemd `OnCalendar` |

## Tags

`replica`, `packages`, `role`, `job`, `sync`
