# Deployment guide — v1

Everything needed to take the website from nothing to running on the web VM, in
order. `docs/server3-proxmox.md` has the detail for building the VM itself;
this guide links to it rather than repeating it.

```
  Render (public)          web VM jengasec-vm 192.168.40.11
        │                          │   website + range API (127.0.0.1:8080)
        └──── read + write ────────┤
                    ▼              │
             Neon  (PRIMARY)       │   the only copy anything writes to
                    │
        logical replication — one way
                    ▼
     database VM 192.168.40.45 : jengasec_web   (read-only copy)
```

**Not used in v1:** Tailscale, Cloudflare. Remote access is the Strathmore VPN.

**Who does what**

| Step | Who |
|---|---|
| Remote access request | You → Strathmore ICT |
| Logical replication in Neon | The Neon project owner |
| Logins and `pg_hba.conf` on 192.168.40.45 | Whoever administers the database VM |
| Everything else | You, on the web VM |

---

## 1. Remote access — the Strathmore VPN

The approved route in is the university's FortiClient VPN, then SSH to your
own account (`Documentation/Strathmore_VPN_Secure_Remote_Server_Access_Documentation.pdf`).
Ask ICT for:

- VPN access for each person who needs the VM.
- The **VPN source range** — the addresses VPN users arrive from. It goes into
  `jengasec_vpn_cidrs` in `inventories/v1/group_vars/all/main.yml`, which opens
  SSH to it. Do not guess it.
- A route from the VPN to `192.168.40.11` on TCP 22.

Until ICT answers, do everything from inside the lab.

**Why not a reverse SSH tunnel.** It needs a server with a public address that
the VM dials out to, and everyone's access then runs through that server. It
also routes around the university firewall, which the ICT regulations say needs
their authorisation. If ICT agree to it in writing, it can be added; it should
not be the first plan.

## 2. Signing in: one shared `netadmin` password

Everyone signs in as `netadmin`, the account the Debian installer created, with
its password. There are no SSH keys and no per-person accounts.

1. On the VM, give `netadmin` a long password. This prints a good one:

   ```bash
   openssl rand -base64 18
   ```
   ```bash
   sudo passwd netadmin
   ```

2. Hand it over **in person**, never by chat or email.
3. **Change it whenever someone leaves the team.** It is the only way to
   remove one person's access.

What keeps a password login safe enough here: SSH answers only the lab LAN and
the VPN range, fail2ban bans an address after 3 wrong passwords, and SSH
accepts no account except `netadmin`. Never open port 22 to `any`.

The trade-off, knowingly accepted: logs show `netadmin` did something, not who.
The Strathmore remote-access plan prefers individual accounts (§4, §9). If ICT
make that a condition of VPN access, per-person accounts can be switched back
on.

## 3. Generating the secrets

Run these on the web VM. Each prints a value to paste into the vault in
step 7. `openssl rand -hex 32` gives 64 hex characters, which are safe in URLs,
YAML and config files alike.

| Vault key | Needed in v1? | How |
|---|---|---|
| `vault_django_secret_key` | Yes | **Copy from Render** → jengasec → Environment → `DJANGO_SECRET_KEY`. It must match, or people get signed out moving between the two sites. |
| `vault_jengasec_db_url` | Yes | **Copy from Render** → `JENGASEC_DB_URL` (the Neon pooled URL) |
| `vault_s3_bucket`, `_endpoint_url`, `_region`, `_access_key_id`, `_secret_access_key` | Yes | **Copy from Render** → `S3_*` |
| `vault_brevo_api_key` | Yes | **Copy from Render** → `BREVO_API_KEY` |
| `vault_django_token_key` | Yes | **Copy from Render** → `DJANGO_TOKEN_KEY` |
| `vault_django_deploy_token` | If Render has it | **Copy from Render** → `DJANGO_DEPLOY_TOKEN` |
| `vault_django_cron_token` | **No** | Leave unset. Render runs the reminders; two copies send every email twice. |
| `vault_postgresql_jengasec_password` | Yes | `openssl rand -hex 32` |
| `vault_redis_password` | Yes | `openssl rand -hex 32` |
| `vault_grafana_admin_password` | Yes | `openssl rand -hex 32`. Also store it somewhere you can find it; it is the Grafana login. |
| `vault_ca_passphrase` | Yes | `openssl rand -hex 32`. Protects the internal certificate authority's key. |
| `vault_replica_admin_user` / `_password` | For the replica | From the database VM admin, step 5 |
| `vault_replica_owner_password` | For the replica | `openssl rand -hex 32` |
| `vault_portal_admin_token` | Later | Handed over in person by the range team |
| `vault_backup_gpg_passphrase` | No | v1 backups are not encrypted (`backup_encrypt: false`) |
| `vault_rndc_key` | No | Not read by the DNS role |
| `vault_jengasec_password_hash` | No | `netadmin`'s password is set by hand (step 2), not from the vault |
| `vault_postgresql_replication_password`, `vault_haproxy_*`, `vault_minio_*`, `vault_smtp_*`, `vault_cloudflare_*`, `vault_tailscale_*` | No | Leave as `CHANGE_ME` |

## 4. Neon

Done by whoever owns the Neon project, at https://console.neon.tech.

1. Open the project Render uses → **Settings → Logical Replication → Enable**.
   It restarts the database for a few seconds, and it cannot be turned off
   again while a replica is subscribed.
2. Confirm it in **SQL Editor**:

   ```sql
   SHOW wal_level;            -- must say: logical
   ```

3. Note the PostgreSQL version on the project dashboard. It must be 17 or
   lower; otherwise raise `replica_pg_client_version` in
   `roles/replica/defaults/main.yml`.

Nothing else is needed in Neon. The website's URL is the same one Render
already uses. The replica works out the direct (non-pooler) address from it,
and creates the publication and slot itself.

**Check after the replica has run** (step 9), in the SQL Editor:

```sql
SELECT slot_name, active FROM pg_replication_slots;   -- jengasec_web_sub | t
```

**Watch compute hours.** On the free plan Neon normally suspends an idle
database. Check the dashboard's compute usage the day after the replica starts.

## 5. The database VM (192.168.40.45)

Done by whoever administers that server. It needs three things for the web VM.

**a) Two logins.** As the `postgres` user (`sudo -u postgres psql`). Replace
both passwords with values from `openssl rand -hex 32`, and send them to you
privately:

```sql
-- Creates the copy's database and its subscription. Superuser because
-- CREATE SUBSCRIPTION needs it; pg_hba below lets it in from the web VM only.
CREATE ROLE jengasec_replica LOGIN SUPERUSER PASSWORD 'REPLACE_ME';

-- Owns the copy; read-only use. (The web VM's Ansible also creates this one
-- if it is missing, and sets its password from vault_replica_owner_password.)
CREATE ROLE jengasec_web LOGIN PASSWORD 'REPLACE_ME';
```

On PostgreSQL 16 or later, a narrower login works instead of superuser:
`CREATEDB CREATEROLE`, plus `GRANT pg_create_subscription TO jengasec_replica;`
and `GRANT jengasec_web TO jengasec_replica WITH SET TRUE;`.

**b) `pg_hba.conf` entries** for the web VM only. Find the file with
`sudo -u postgres psql -c 'SHOW hba_file;'` and add, above any broader `host`
lines:

```
# JengaSec website replica — from the web VM only
host  postgres      jengasec_replica  192.168.40.11/32  scram-sha-256
host  jengasec_web  jengasec_replica  192.168.40.11/32  scram-sha-256
host  jengasec_web  jengasec_web      192.168.40.11/32  scram-sha-256
```

Then reload. A reload does not interrupt anything already connected:

```bash
sudo -u postgres psql -c 'SELECT pg_reload_conf();'
```

**c) Network.** PostgreSQL must listen on the LAN address
(`SHOW listen_addresses;` includes `*` or `192.168.40.45`), and any firewall on
that server must allow 5432 from `192.168.40.11`. The server also needs
**outbound** internet to Neon on 5432, because the subscription connects from
there to Neon:

```bash
nc -zv <the-neon-host-from-the-url> 5432
```

Use the Neon host without `-pooler`.

**Test from the web VM** before going further:

```bash
psql "host=192.168.40.45 user=jengasec_replica dbname=postgres" -c 'SELECT version();'
```

## 6. Build the VM

Follow `docs/server3-proxmox.md` **Stages 1–4**. Skip Stage 0 and Stage 8,
which are Tailscale. You end with VM 101 `jengasec` on `192.168.40.11` and a
`networked` snapshot.

## 7. Make the VM its own control node

Log in as `netadmin` (the installer account), on the Proxmox console or by
SSH from inside the lab.

```bash
sudo apt install -y ansible-core git make python3-jinja2 python3-yaml
sudo git clone https://github.com/JengaSec-Org/jengasec-website-infrastructure.git /srv/jengasec-infrastructure
cd /srv/jengasec-infrastructure
ansible-galaxy collection install -r requirements.yml
```

One shared clone in `/srv`, so every admin runs the same files with the same
vault, rather than each keeping their own copy. Give admins write access:

```bash
sudo chgrp -R sudo /srv/jengasec-infrastructure && sudo chmod -R g+rwX /srv/jengasec-infrastructure
sudo find /srv/jengasec-infrastructure -type d -exec chmod g+s {} +
```

**The vault:**

```bash
cp inventories/v1/vault.yml.example inventories/v1/vault.yml
nano inventories/v1/vault.yml                 # paste the values from step 3
openssl rand -hex 32 > .vault_pass && chmod 660 .vault_pass
ansible-vault encrypt --vault-password-file .vault_pass inventories/v1/vault.yml
```

Then uncomment `vault_password_file = .vault_pass` in `ansible.cfg`. Both
`vault.yml` and `.vault_pass` are gitignored. Keep a copy of the vault password
somewhere safe off the VM; without it the vault cannot be opened.

**Check everything before touching the system:**

```bash
export INVENTORY=inventories/v1
make structure && make syntax && make preflight && make ping
```

## 8. Deploy

Every command needs `ANSIBLE_ARGS=-K`, because sudo asks for `netadmin`'s
password. Do a dry run with `make check` first if you
want to see what will change.

```bash
export INVENTORY=inventories/v1 ANSIBLE_ARGS=-K
```

| # | Command | What to watch |
|---|---|---|
| 1 | `make bootstrap` | Rewrites the SSH config. Before closing your session, open a **second** one (`ssh netadmin@192.168.40.11`) and confirm the password still works. |
| 2 | `make networking` | Keep the Proxmox console open. It rewrites the network config. |
| 3 | `make security` | |
| 4 | `make database` | Installs a local PostgreSQL. The website's data is in Neon, so this PostgreSQL sits idle; it is left in place rather than removed. |
| 5 | `make platform` | The website. The end of the run prints the platform's `preflight` report: no blockers, and storage must say object storage. |
| 6 | `make monitoring` | Grafana on `http://192.168.40.11:3000` |
| 7 | ~~`make backup`~~ | **Skip in v1.** It would back up the empty local database over an SSH account that has no key, and fail every night. The real data is backed up **hourly on the database VM** by `scripts/cutover/setup-database-vm.sh` (`ls -lh /var/backups/jengasec_web/` there). |

## 9. Start the replica

Needs steps 4 and 5 done. Set `replica_enabled: true` in
`inventories/v1/group_vars/web/main.yml`, then:

```bash
make replica
```

It should finish with `OK - N of N tables in sync`. After that it re-checks
every ten minutes by itself:

```bash
journalctl -u jengasec-replica-sync -n 20
```

## 10. Check it is one website

1. `https://192.168.40.11/healthz/` answers 200. Accept the certificate warning;
   it comes from the internal CA.
2. Sign in. If the form just reloads, see "The HTTPS trap" in the platform's
   `docs/VENUE-HOSTING.md`.
3. Rename a test team on **Render**, then refresh the VM's site: it changed.
   Then the other way round.
4. Upload a small file on one, open it on the other.
5. On the database VM, the rename from point 3 is there too:

   ```bash
   psql -h 192.168.40.45 -U jengasec_web jengasec_web -c "SELECT team_name FROM accounts_team ORDER BY id DESC LIMIT 5;"
   ```

## When someone leaves the team

```bash
sudo passwd netadmin
```

Give the new password to everyone who still needs it, in person. Ask ICT to end
the leaver's VPN access too.
