# `deployment`

**Phase 7 · Implemented**

Ships a new revision onto a platform that already exists.

## Different from the `django` role

| | `django` | `deployment` |
|---|---|---|
| Job | **Builds** the platform | **Ships a change** to a running one |
| Runs | Once per host, then rarely | Every release |
| Cares about | Checkout, virtualenv, units, first migration | What was running before, whether the new version works, how to preserve state for repair |

A failed deployment stops for a compatible forward correction.

## The sequence

```
record current revision  →  refuse if dirty  →  fetch  →  requirements
    →  migrate  →  collectstatic  →  reload  →  health check
        → pass: log the release
        → fail: preserve current source and state, keep requested maintenance, fail
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

Migrations and static collection load `deployment_env_file`, which defaults to
the Django role's runtime environment at `app_root/.env`. The file must use the
same `KEY=value` format as that role and select a database through
`JENGASEC_DB_URL` or `JENGASEC_DB_NAME`, `JENGASEC_DB_HOST` and `JENGASEC_DB_USER`.
A missing or incomplete file stops deployment before checkout. The commands
receive that environment; environment contents and command output are redacted.
They do not silently run against a checkout-local SQLite database.

## Repair forward after a failure

Failures in checkout, dependencies, migrations, static collection, reload or
verification stop the play. The role leaves the current source, installed
dependencies, applied migrations, database contents, media and static files in
place. It does not restore an earlier release or reverse migrations. A partial
migration or static collection may already have changed state; inspect the
failed task before preparing a compatible correction.

Preserve evidence, immutable score revisions, scoring policy, queued telemetry,
outbox rows and pending acknowledgements. Do not reset or recreate those stores
to make a retry succeed. Deploy a reviewed correction and verify the actual
application and affected scoring path. A code version does not restore database
contents or runtime effects. A code fix that implements the same scoring rules
keeps the frozen policy; changed rules require explicit policy handling.

`deployment_rollback_on_failure` defaults to `false`. A legacy inventory value
of `true` is rejected before deployment; remove it or set it to `false`.

Emergency containment remains available. Stop an unsafe publication operation,
remove harmful restrictions, or contain traffic through the configured ingress
when an incident requires it. These actions do not require reverting a code
release. A release rollback is an incident-specific exception: record why a
forward correction cannot address the incident adequately, and check the older
code against the current schema and retained state before using it.

## Verify the intended application

The default check sends `/healthz/` to the configured Gunicorn Unix socket with
`deployment_healthcheck_host` as the HTTP Host. It requires status 200 and the
platform's existing JSON response: `{"status": "ok", "database": "ok"}`.
Redirects and environment proxies are disabled. A default web page returning
200 cannot mark the release healthy, and a failed socket never falls back to a
TCP listener.

For a TCP deployment, set `deployment_healthcheck_unix_socket: ""`, provide the
explicit application origin in `deployment_healthcheck_url`, and set the correct
Host. HTTPS verifies certificates by default, using the system trust store or
the CA file in `deployment_healthcheck_ca_path`; there is no insecure retry. A socket
check proves the application and database endpoint; verify the intended ingress
and the affected user flow separately before declaring the release operational.

## Reload, not restart

gunicorn re-execs its workers while holding the socket open. Nothing in flight
is dropped, and requests arriving during the reload are queued by the kernel.

That is also why the **maintenance page is off by default** — the pause is a
second or two, and a maintenance page would be more disruptive than the thing it
covers. Turn it on for a deployment with a long migration, where the pause is
minutes. The role removes the configured maintenance file only after successful
verification. A failure leaves it in place. The ingress must already serve this
file for it to contain traffic; the deployment role does not configure that route.

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
| `deployment_env_file` | Configured `django_env_file`, default `app_root/.env` |
| `deployment_healthcheck_url` | `http://<application-host>/healthz/` |
| `deployment_healthcheck_host` | Configured `nginx_server_name` |
| `deployment_healthcheck_unix_socket` | Configured `gunicorn_socket_path`, default `/run/gunicorn/gunicorn.sock` |
| `deployment_healthcheck_retries` | `5`, 5s apart |
| `deployment_healthcheck_validate_certs` | `true` |
| `deployment_healthcheck_ca_path` | Empty; use system trust |
| `deployment_rollback_on_failure` | `false`; `true` is rejected |
| `deployment_maintenance_page` | `false` |

## Tags

`deployment`, `state`, `code`, `migrate`, `static`, `reload`, `verify`,
`maintenance`

## Verifying

```bash
curl --fail --unix-socket /run/gunicorn/gunicorn.sock \
    -H 'Host: <application-host>' http://localhost/healthz/
cat /opt/jengasec/.deploy/releases.log
sudo -u jengasec git -C /opt/jengasec/app log --oneline -5
journalctl -t jengasec-deploy --since today
```

## Validate the deployment role

Run `python tests/deployment-check.py` with `ansible-core`, PyYAML and Jinja2
installed. The check uses temporary local source, database, media and HTTP
fixtures. It exercises failure and forward repair without calling a host service,
installing application packages or loading a deployment inventory.
