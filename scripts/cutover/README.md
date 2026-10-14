# Cutover: Neon → the database VM

The campus network blocks outgoing PostgreSQL (port 5432), so the website VM
cannot use Neon. Instead, only one copy of the website accepts writes at a time:

```
until the cutover              cutover (≈1 hour)                 event days
─────────────────────          ─────────────────────────         ─────────────────────────────
Render + Neon = live site      freeze Render                     jengasec-vm + database VM
(registrations, as today)      export Neon at home  ───────────► = the live site
                               import on the database VM         Render suspended / read-only
```

| Script | Where it runs | When |
|---|---|---|
| `export-from-neon.ps1` | Your Windows laptop, **off campus** | Rehearsal, then cutover |
| `setup-database-vm.sh` | Database VM (192.168.40.45) | Once |
| `import-to-database-vm.sh` | Database VM | Rehearsal, then cutover |

**Backblaze does not move.** Uploaded files stay in the same bucket, and the
website VM uses the same `vault_s3_*` keys as Render. Only the database rows
move, and they point at the same files. Backblaze is reached over HTTPS (443),
which the campus allows. One consequence: a campus internet outage stops
uploads and downloads, though the rest of the site keeps working.

---

## Step 1 — At home, once: install the PostgreSQL tools

1. Go to https://www.enterprisedb.com/downloads/postgres-postgresql-downloads and
   download **PostgreSQL 17 for Windows x86-64**.
2. Run the installer. On **Select Components**, tick only **Command Line Tools**
   and untick the server, pgAdmin and Stack Builder. You do not want a database
   server on your laptop.
3. Check it, in PowerShell:

   ```powershell
   & "C:\Program Files\PostgreSQL\17\bin\pg_dump.exe" --version
   ```

The export script finds the tools there by itself.

## Step 2 — On the database VM, once: create the website's database

Copy the two `.sh` scripts over, from this folder on your laptop while on campus
(Windows has `scp` built in):

```powershell
scp .\setup-database-vm.sh .\import-to-database-vm.sh netadmin@192.168.40.45:~/
```

Then on the database VM:

```bash
sudo bash setup-database-vm.sh
```

It creates the `jengasec_web` role and database, lets only the website VM in,
and **prints the database URL once**. Copy that URL now.

It changes nothing else on that server. The API's database is left alone.

If it warns that PostgreSQL only listens on localhost, it prints the fix. That
fix needs a PostgreSQL restart, which briefly interrupts the API too, so agree a
moment with the range team.

## Step 3 — On the website VM, once: point the website at it

```bash
ansible-vault edit inventories/v1/vault.yml
```

Set:

```yaml
vault_jengasec_db_url: "postgresql://jengasec_web:<password>@192.168.40.45:5432/jengasec_web?sslmode=prefer"
```

Keep `?sslmode=prefer` at the end. Without it the website demands TLS, which
the database VM may not offer.

Check the connection from the website VM:

```bash
timeout 5 bash -c '</dev/tcp/192.168.40.45/5432' && echo OPEN || echo BLOCKED
```

Then deploy:

```bash
make platform INVENTORY=inventories/v1 ANSIBLE_ARGS="-K -e @inventories/v1/vault.yml"
```

The site now runs on an **empty** database. That's expected; the import fills it.

## Step 4 — Rehearse the cutover, now

Do the whole thing once before the real day, so the real one is boring.

**At home** (PowerShell, in this folder):

```powershell
powershell -ExecutionPolicy Bypass -File .\export-from-neon.ps1
```

Paste the Neon URL when asked: Render → jengasec → Environment →
`JENGASEC_DB_URL`. You get three files: `.sql`, `.counts` and `.sha256`.

**On campus**, copy all three files to the database VM:

```powershell
scp .\jengasec-neon-*.sql .\jengasec-neon-*.counts .\jengasec-neon-*.sha256 netadmin@192.168.40.45:~/
```

**On the database VM:**

```bash
sudo bash import-to-database-vm.sh jengasec-neon-<date>.sql --replace
```

`--replace` is needed because step 3 already created empty tables. It should
end with **VERIFIED**, meaning every table's row count matches the export.

In the rehearsal Render is still live. If someone registered in the seconds
between the export and its row count, a table may be off by one or two
(usually `django_session`). That's the rehearsal's only false alarm; export
again. On the real day Render is suspended first, so the counts must match
exactly.

**On the website VM:**

```bash
make platform INVENTORY=inventories/v1 ANSIBLE_ARGS="-K -e @inventories/v1/vault.yml"
```

This applies any newer migrations and restarts the site. Then sign in on
`https://192.168.40.11` and check your registrations are there.

**Note how long each part took.** That is the length of the freeze on the real
day.

## Step 5 — The real cutover

| # | Where | Action |
|---|---|---|
| 1 | Anywhere | Announce it: "Registration closes at HH:MM". |
| 2 | Render dashboard | At HH:MM, go to the jengasec service → **Settings → Suspend Web Service**. Nothing can write to Neon from now on. |
| 3 | Home | Run `export-from-neon.ps1`. The export works with Render suspended, because it talks to Neon directly. |
| 4 | Campus | `scp` the three files to the database VM. |
| 5 | Database VM | `sudo bash import-to-database-vm.sh jengasec-neon-<date>.sql --replace`, and wait for **VERIFIED**. |
| 6 | Website VM | `make platform ...` |
| 7 | Browser | Sign in, check teams and registrations, upload a small test file. |
| 8 | Laptop and database VM | Delete the export files: `shred -u jengasec-neon-*` on the VM; on Windows, delete them and empty the Recycle Bin. |

**From step 2 on, the website VM is the only live copy.** Do not resume Render
while the event runs. Anything written there would never reach the VM.

**If step 5 fails,** the import rolls back completely and nothing is
half-loaded. You can resume Render and try again later; no data was lost,
because Neon was never changed.

## After the event (optional)

To put the final data back into Neon (for certificates, results or the public
site), do the same in reverse. `pg_dump` the `jengasec_web` database on the
database VM, carry the file home, and load it into Neon with `psql`. Ask before
doing that one: it replaces what is in Neon.
