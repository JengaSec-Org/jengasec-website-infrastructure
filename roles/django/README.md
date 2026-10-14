# `django`

**Phase 4 · Implemented**

Deploys the JengaSec platform: code, virtualenv, environment, migrations, static
files.

The only role that touches application state. Everything runs as the app user,
never as root.

## Variable names are not negotiable

Every name in [`templates/env.j2`](templates/env.j2) matches `config/settings.py`
in the platform repository **exactly**.

Renaming one does not raise an error. Django falls back to its default — and for
`JENGASEC_DB_NAME` that fallback is **SQLite**, which means production quietly
running on a file that no backup covers and that every deploy could overwrite.

That is why the template writes `JENGASEC_DB_NAME` unconditionally.

## Four guards

| Guard | Prevents |
|---|---|
| `DEBUG` must be off in production | A full traceback — settings and environment included — served to anyone who triggers an error, with `ALLOWED_HOSTS` no longer enforced |
| `ALLOWED_HOSTS` must be non-empty | Django returning 400 to every request; the site answers nothing at all |
| Checkout must contain the proxy settings | **See below** |
| Database must be reachable before migrating | A wall of psycopg2 traceback that never mentions the firewall |

### The proxy-settings guard

The role greps the checkout for `SECURE_PROXY_SSL_HEADER` and
`CSRF_TRUSTED_ORIGINS` and **refuses to deploy without them**.

Behind nginx with TLS, Django 4+ rejects every login POST whose `Origin` is not
trusted, with a CSRF error that does not name the cause. The site would deploy
cleanly, look fine, and be unusable — discovered at the login page, during the
event.

If this guard fires, the platform repository needs updating. See
[pre-deployment.md](../../docs/pre-deployment.md), "Platform-side changes".

## nginx serves static and media — that is not optional

`whitenoise` is in `requirements.txt` but **not in `MIDDLEWARE`**, and
`config/urls.py` serves media only when `DEBUG` is true. With `DEBUG=False`,
Django serves **neither**.

So `collectstatic` writing to `staticfiles/` and nginx serving from disk is the
only path that works. Skip it and the site renders unstyled.

Permissions reflect what each actually is:

| Directory | Mode | Why |
|---|---|---|
| `staticfiles/` | `0755` `:www-data` | Public assets — CSS, JS, logos |
| `media/` | `0750` `:www-data` | **Submissions.** Not public. nginx reads them through group membership, not world permissions |

## No superuser is created

`django_superuser_create` is false and should stay false. Creating one
non-interactively means its password exists in a variable somewhere, and that
account can see every submission and change every score.

Make it by hand, once:

```bash
sudo jengasec-manage createsuperuser
```

## Always `jengasec-manage`, never `manage.py` directly

The environment file lives at `/opt/jengasec/.env`, outside the checkout, and
`settings.py` only auto-loads a `.env` *inside* it. Run `manage.py` bare and it
sees no database settings, falls back to SQLite, and every command "succeeds"
against an empty file — a superuser created that way cannot sign in anywhere.

The role installs `/usr/local/bin/jengasec-manage`, which loads the same file
gunicorn reads and runs as the app user. The role's own `manage.py` tasks get
the same environment by parsing that file.

## Sharing a database with Render (venue hosting)

Set `vault_jengasec_db_url` (plus the `vault_s3_*` and `vault_brevo_api_key`
values, and Render's `DJANGO_SECRET_KEY` as `vault_django_secret_key`) and this
host becomes a second front door onto the same data as www.jengasec.com — see
`docs/VENUE-HOSTING.md` in the platform repository. The URL replaces the local
`JENGASEC_DB_*` settings entirely.

Two rules from that doc are enforced or flagged here:

- **One scheduler.** Leave `vault_django_cron_token` unset while Render holds
  `DJANGO_CRON_TOKEN`, or every reminder email is sent twice. The role warns.
- **Insecure cookies only off the internet.** `django_insecure_cookies` makes
  sign-in work over plain HTTP before TLS exists. The role refuses it when the
  Cloudflare tunnel is enabled.

## Reload, never restart

Every task that changes code or environment notifies **reload gunicorn** —
`SIGHUP`, which re-execs workers while holding the socket open. Nothing in
flight is dropped.

## `django_force_checkout` is false

A checkout that would overwrite local modifications **fails** rather than
discarding them. On a server where someone may have hot-fixed something at 2am,
silently throwing that away is worse than a failed play.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `django_repo_url` / `_branch` | platform repo, `main` | |
| `django_debug` | `false` | Guarded |
| `django_allowed_hosts` | `[]` | Required; set in `group_vars/web` |
| `django_csrf_trusted_origins` | derived from allowed hosts | Scheme included |
| `django_db_url` | `vault_jengasec_db_url` | Hosted database; wins over `django_db_*` |
| `django_db_*` | see defaults | `JENGASEC_DB_NAME` switches off SQLite |
| `django_db_sslmode` | `prefer` | `verify-full` once the CA is trusted |
| `django_run_migrations` | `true` | |
| `django_collectstatic` | `true` | Required, not optional |
| `django_superuser_create` | `false` | Leave it |
| `django_require_proxy_settings` | `true` | Leave it |
| `django_redis_enabled` | `false` | settings.py does not read these yet |
| `django_s3_*` | `vault_s3_*` | Uploads to a bucket instead of `media/` |
| `django_brevo_api_key` | `vault_brevo_api_key` | Selects the Brevo email backend |
| `django_email_backend` | Brevo if keyed, else SMTP | An explicit value always wins |
| `django_site_url` | first allowed host | Base for links in emails |
| `django_insecure_cookies` | `false` | Venue-only escape hatch; guarded |
| `django_token_key` / `_deploy_token` / `_cron_token` | from vault, empty | Empty = not written |
| `django_run_preflight` | `true` | The platform's `manage.py preflight`, as a report |

## Tags

`django`, `directories`, `source`, `venv`, `env`, `database`, `migrate`,
`static`, `permissions`, `verify`

Redeploy code without touching the database:

```bash
ansible-playbook -i inventories/production playbooks/platform.yml --tags source,venv,static
```

## Verifying

```bash
sudo jengasec-manage check --deploy
sudo jengasec-manage preflight
sudo jengasec-manage showmigrations
ls -l /opt/jengasec/app/staticfiles/ | head
sudo -u www-data test -r /opt/jengasec/app/media/. && echo "nginx can read media"
```

`check --deploy` will warn about `SECURE_SSL_REDIRECT` and
`SECURE_HSTS_SECONDS`. Both are **expected** — nginx handles them, and setting
them in Django too would give one policy two owners.
