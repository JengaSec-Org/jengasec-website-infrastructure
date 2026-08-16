# `deployment`

**Phase 7 · Implemented**

Ships a new revision onto a platform that already exists.

## Different from the `django` role

| | `django` | `deployment` |
|---|---|---|
| Job | **Builds** the platform | **Ships a change** to a running one |
| Runs | Once per host, then rarely | Every release |
| Cares about | Checkout, virtualenv, units, first migration | What was running before, whether the new version works, how to get back |

This is the playbook that runs most often, so it has to be boring and
reversible.

## The sequence

```
record current revision  →  refuse if dirty  →  fetch  →  requirements
    →  migrate  →  collectstatic  →  reload  →  health check
        → pass: log the release
        → fail: roll back code, reload, fail loudly
```

## It refuses to deploy over uncommitted changes

`git status --porcelain` is not empty means **someone hot-fixed something on the
server**. Deploying over it destroys the fix *and* the evidence of what was
wrong — and whoever did it is probably not in the room.

Investigate first, then either commit the change upstream or set
`deployment_refuse_if_dirty: false` to discard it deliberately.

## Migrations run before the reload

The old code has to tolerate the new schema for the moment between them.

That makes **additive** migrations (add a column, add a table) safe to deploy
this way, and **destructive** ones (drop or rename a column) unsafe — those need
two releases: one that stops using the column, one that removes it.

Worth knowing before writing the migration, not after.

## Rollback restores code, not the database

`deployment_rollback_on_failure` checks the previous revision back out and
reloads. It **cannot undo a migration**.

If a migration ran and the health check then failed, the rolled-back code is now
running against a newer schema. The role says so explicitly in its failure
message rather than letting you assume the rollback was complete — because
rolling code back past a migration usually breaks worse than the thing you were
fixing.

## The health check hits `/healthz/`, not `/`

`/healthz/` runs `SELECT 1` and returns 200 or 503. A 200 means the application
started **and** can reach the database.

Checking `/` would be nearly worthless: it is a `TemplateView` touching no
database, so it returns 200 with PostgreSQL completely down. A health check that
passes while the application cannot serve a single real page is worse than none,
because it creates confidence.

The endpoint is added by the platform-side change described in
[pre-deployment.md](../../docs/pre-deployment.md).

## Reload, not restart

gunicorn re-execs its workers while holding the socket open. Nothing in flight
is dropped, and requests arriving during the reload are queued by the kernel.

That is also why the **maintenance page is off by default** — the pause is a
second or two, and a maintenance page would be more disruptive than the thing it
covers. Turn it on for a deployment with a long migration, where the pause is
minutes.

## The release log

Each successful deployment appends to `.deploy/releases.log`:

```
2026-10-05T14:22:01Z  a3f9c21...  v1.2.0  migrations
```

During an incident, "what changed and when" is the first question. This answers
it without needing git, and the deployment is also announced to the journal — so
`journalctl` shows a deployment happening right before things changed.

## Pin the revision for the competition

`deployment_revision: HEAD` means "whatever `main` happens to be". Fine
mid-development; wrong the week of the event, where you want to know exactly
what is running:

```bash
ansible-playbook -i inventories/production playbooks/deployment.yml \
    -e deployment_revision=v1.0.0
```

`playbooks/deployment.yml` sets `serial: 1`, so with more than one web host they
are deployed one at a time and a bad release cannot take out both.

## Variables

| Variable | Default |
|---|---|
| `deployment_revision` | `HEAD` — pin it for a real release |
| `deployment_refuse_if_dirty` | `true` |
| `deployment_run_migrations` | `true` |
| `deployment_healthcheck_url` | `https://<server_name>/healthz/` |
| `deployment_healthcheck_retries` | `5`, 5s apart |
| `deployment_rollback_on_failure` | `true` |
| `deployment_maintenance_page` | `false` |

## Tags

`deployment`, `state`, `code`, `migrate`, `static`, `reload`, `verify`,
`rollback`, `maintenance`

## Verifying

```bash
curl -k https://platform.jengasec.local/healthz/
cat /opt/jengasec/.deploy/releases.log
sudo -u jengasec git -C /opt/jengasec/app log --oneline -5
journalctl -t jengasec-deploy --since today
```

## Rolling back by hand

```bash
ansible-playbook -i inventories/production playbooks/deployment.yml \
    -e deployment_revision=<previous-sha> \
    -e deployment_run_migrations=false
```

`deployment_run_migrations=false` matters: you are going backwards, and Django
would otherwise try to apply migrations that the older code does not have.
