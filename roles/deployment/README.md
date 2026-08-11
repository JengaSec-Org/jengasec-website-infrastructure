# `deployment`

**Phase 7 · NOT YET IMPLEMENTED**

Application release, rollback, and service orchestration.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Pull the target revision and record it
- Run migrations and collectstatic in the right order
- Restart services in dependency order
- Health check after release, and roll back if it fails
- Keep the previous release available for instant rollback

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `deployment_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `deployment_revision` | `HEAD` | set to a tag or SHA for a repeatable release |
| `deployment_keep_releases` | `3` | — |
| `deployment_healthcheck_url` | `"https://platform.{{ jengasec_domain }}/"` | — |
| `deployment_healthcheck_retries` | `5` | — |
| `deployment_healthcheck_delay` | `5` | — |
| `deployment_rollback_on_failure` | `true` | — |
| `deployment_maintenance_page` | `true` | serve a holding page during the release |

## Example play

```yaml
- name: Configure deployment
  hosts: infra
  become: true
  roles:
    - role: deployment
      tags: [deployment]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `deployment_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
