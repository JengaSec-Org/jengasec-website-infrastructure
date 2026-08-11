# Secrets

Every secret in this repository lives in an `ansible-vault` encrypted file. No
password, key, or token belongs in a role, a template, or a `group_vars` file.

## The naming convention

Every secret is prefixed `vault_`:

```yaml
vault_django_secret_key: "..."
vault_postgresql_jengasec_password: "..."
```

Two things fall out of that. A `grep -r vault_ roles/` shows exactly what is
sensitive, and at the point of use it is obvious you are handling a secret:

```yaml
redis_requirepass: "{{ vault_redis_password }}"
```

## Setting it up

```bash
cd inventories/production
cp vault.yml.example vault.yml
# edit vault.yml — real values
ansible-vault encrypt vault.yml
```

`vault.yml.example` is committed and must **never** contain a real secret.
`vault.yml` is gitignored.

Generate the values properly rather than inventing them:

```bash
# Django secret key
python3 -c "import secrets; print(secrets.token_urlsafe(64))"

# Passwords
openssl rand -base64 32

# A password HASH for a local account (not the password itself)
mkpasswd --method=sha-512
```

## The vault password

`ansible.cfg` points at `.vault_pass`, which is gitignored:

```bash
echo 'your-vault-password' > .vault_pass
chmod 600 .vault_pass
```

`chmod 600` matters. At the default `644`, every local account on the control
node can read the password that decrypts every secret in the infrastructure.
`preflight.sh` checks this.

**Share the vault password out of band** — in person, or through the club's
password manager. Never in the repository, never in chat, never in email.

## Daily use

```bash
make vault-edit      # decrypt, open $EDITOR, re-encrypt on save
make vault-view      # read-only
```

Or directly:

```bash
ansible-vault edit inventories/production/vault.yml
ansible-vault view inventories/production/vault.yml
ansible-vault rekey inventories/production/vault.yml   # change the password
```

`ansible-vault edit` never writes plaintext to disk. `decrypt` does — avoid it.

## Rotating a secret

1. `make vault-edit`, change the value.
2. Re-run the role that consumes it.
3. Confirm the service still works.
4. Revoke the old value at the source — change the database password, delete the
   API token. **A rotated secret that still works has not been rotated.**

## If a secret is exposed

Assume it is compromised the moment it leaves the vault. Fixing the file is not
enough — `git rm` does not remove anything from history, and anyone with a clone
still has it.

1. **Rotate the secret itself first.** Change the password, revoke the token.
   Everything else is secondary.
2. Then remove it from the repository, and rewrite history if it was pushed
   (`git filter-repo`). Assume it was scraped if the repository is public;
   automated scanners find committed credentials within minutes.
3. Tell the rest of the club, so nobody is surprised by a service that stopped
   working.

## What is in the vault

| Key | Used by |
|---|---|
| `vault_django_secret_key` | `django` — session and CSRF signing |
| `vault_postgresql_jengasec_password` | `postgresql`, `django` |
| `vault_postgresql_replication_password` | `postgresql` (Phase 6) |
| `vault_redis_password` | `redis` |
| `vault_grafana_admin_password` | `monitoring` |
| `vault_smtp_*` | `django` — notification email |
| `vault_jengasec_password_hash` | `users` — console access |
| `vault_ca_passphrase` | `certificates` — **the most sensitive one here** |
| `vault_backup_gpg_passphrase` | `backup` |
| `vault_cloudflare_*` | `cloudflare` (Phase 9) |
| `vault_rndc_key` | `dns` |

`vault_ca_passphrase` deserves the emphasis. It protects the internal CA key,
and anyone holding that key can issue a valid certificate for **any** name in
the network — including the platform's. It is the one secret whose loss
undermines every other TLS guarantee you have.

## Things not to do

**Do not commit `vault.yml` unencrypted.** `preflight.sh` checks the first line
for the `$ANSIBLE_VAULT` header specifically because this is easy to do by
accident after an `ansible-vault decrypt`.

**Do not put secrets in `host_vars` or `group_vars` "temporarily".** Temporary
files get committed.

**Do not disable `no_log`** on tasks that handle secrets. It exists so the value
does not end up in `logs/ansible.log`, which is not encrypted.

**Do not reuse a secret across environments.** Staging exists to be broken; if
it shares a password with production, breaking staging breaks production too.
