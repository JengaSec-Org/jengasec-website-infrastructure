# `django`

**Phase 4 · NOT YET IMPLEMENTED**

Deploy the JengaSec platform: code, virtualenv, environment, migrations.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Clone or update the application repository at app_repo_branch
- Create the virtualenv and install requirements.txt
- Render the .env file from vault-backed variables
- Run manage.py migrate
- Run manage.py collectstatic
- Set ownership and permissions on media and static directories
- Notify the gunicorn handler to reload

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `django_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `django_settings_module` | `"config.settings"` | matches the platform layout |
| `django_debug` | `false` | MUST stay false in production |
| `django_allowed_hosts` | `[]` | set per host group |
| `django_run_migrations` | `true` | — |
| `django_collectstatic` | `true` | — |
| `django_superuser_create` | `false` | create the first admin by hand, interactively |
| `django_env_file` | `"{{ app_root }}/.env"` | — |
| `django_email_backend` | `"django.core.mail.backends.smtp.EmailBackend"` | — |

## Example play

```yaml
- name: Configure django
  hosts: web
  become: true
  roles:
    - role: django
      tags: [django]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `django_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
