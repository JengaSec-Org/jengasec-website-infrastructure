# `backup`

**Phase 10 · Implemented**

Encrypted, rotated, verified backups of the database, submissions, and
configuration.

This guards the only data in the whole system that cannot be recreated: what
teams submitted and what judges scored.

## It pulls, it does not push

server3 reaches out to server1 and server2. The source hosts have no route into
the backup host at all.

**A compromised web host cannot delete its own backups.** With a push model it
can — and deleting the backups is the first thing ransomware does. That property
is worth the extra setup below.

## The setup this needs — read before running

The `users` role creates `backup` with `/usr/sbin/nologin` on every host, which
blocks rsync-over-SSH. The role gives the account a shell **on server3 only**,
generates a key, and prints the line to install on each source host:

```
command="/usr/bin/rrsync -ro /",restrict,from="10.0.0.13" ssh-ed25519 AAAA...
```

Three restrictions, each doing real work:

| | |
|---|---|
| `command="rrsync -ro /"` | The key can run **one read-only rsync** and nothing else. Not a shell. |
| `restrict` | No port forwarding, no agent forwarding, no PTY, no X11 |
| `from="…"` | Only from the backup host's address |

Even stolen, this key gets an attacker a read-only file copy from one address.

The role **cannot install this itself** — it would need root on server1 and
server2 from within a play targeting server3. It prints the exact line instead,
which is the honest alternative to a task that silently does nothing.

Install `rrsync` on the source hosts (`/usr/share/rsync/scripts/rrsync` in
Debian's `rsync` package; symlink it into `/usr/bin`).

## Encryption

GPG, to a **public** key. The backup host holds only the public half, so it can
write backups it cannot read.

That is the point: someone who compromises server3 — which is also the
monitoring host, and therefore reachable from the LAN — gets encrypted archives
and nothing else.

```bash
# on a machine that is NOT server3
gpg --full-generate-key
gpg --armor --export backups@jengasec > jengasec-backup.pub.asc
# put that file in roles/backup/files/
```

**Keep the private key somewhere else, and make sure more than one person can
reach it.** A backup nobody can decrypt is not a backup — and the natural place
to store the private key is precisely the environment you would be recovering
from.

## Retention

Three tiers, pruned by **count, not age**:

| Tier | Keeps | Promoted |
|---|---|---|
| daily | 7 | — |
| weekly | 4 | from Sunday's daily |
| monthly | 6 | from the 1st |

Promotion **copies**, it does not move — otherwise Sunday's backup would vanish
from the daily tier the moment it was promoted.

Pruning by count rather than age matters more than it looks: age-based pruning
on a host whose backups have been failing for a fortnight deletes the last good
ones it has.

## Verification is the point

`backup_verify_enabled` restores the newest dump into a scratch database on
server2, counts the tables, and drops it — monthly.

**A backup that has never been restored is a hope, not a backup.** A corrupt or
truncated dump looks exactly like a good one until you try it, and the moment
you try it is usually the moment you needed it.

The table count is the real test. A dump that restores with zero tables restores
"successfully".

> **Verification needs the private key**, which deliberately is not on this
> host. So the monthly timer will fail its decryption step until you either
> import the key temporarily or run `jengasec-backup-verify` from the machine
> that holds it. The script says so explicitly rather than failing obscurely.
>
> That tension is real and worth deciding deliberately: automated verification
> and key separation pull in opposite directions. Running the verification by
> hand each month from a laptop that holds the key is a reasonable answer.

## `jengasec-restore`

Written now, in calm conditions, because the moment you need it is the worst
time to be working out `pg_restore` flags.

```bash
jengasec-restore --list
jengasec-restore --database 20261005 --into jengasec_recovered
jengasec-restore --media 20261005 --target /tmp/media-check
```

**It refuses to restore over the live database without `--force`.** Recovering
one deleted submission is far more common than rebuilding everything, and the
destructive path should not be one typo away. Restoring into a scratch copy and
moving the rows across is reversible; overwriting is not, and it discards
everything written since the backup.

## systemd timers, not cron

`Persistent=true`. If the host was down at 02:00, the backup runs when it comes
back — and the nights a server is down are exactly the nights you want a backup
afterwards. cron would simply skip.

Both units carry `OnFailure=jengasec-backup-failed.service`, which mails the
last 40 journal lines. Without it a failing backup is visible only to whoever
runs `journalctl`, and nobody runs `journalctl` on a server that appears to be
working. That is how a backup job stops for six weeks and is discovered on the
day it is needed.

## Guards

| Guard | Prevents |
|---|---|
| Refuses empty `backup_sources` | A job that runs nightly, succeeds, and backs up nothing |
| Refuses `backup_encrypt` without a recipient | Submissions and scores in the clear on a shared host |
| Disk check before starting | Filling the partition Prometheus shares |
| Empty-dump detection | `pg_dump` erroring through a pipe and leaving a zero-byte "backup" |
| Freshness check on every Ansible run | A timer that silently stopped firing |

## Variables

| Variable | Default |
|---|---|
| `backup_enabled` | `true` |
| `backup_sources` | `[]` — set in `group_vars/backup` |
| `backup_encrypt` | `true` |
| `backup_gpg_recipient` | `""` — **required** |
| `backup_retention_daily` / `_weekly` / `_monthly` | 7 / 4 / 6 |
| `backup_schedule` | `02:00` |
| `backup_verify_enabled` | `true` |
| `backup_verify_min_tables` | `10` |
| `backup_max_age_hours` | `30` |
| `backup_min_free_percent` | `15` |

## Tags

`backup`, `packages`, `directories`, `ssh`, `gpg`, `scripts`, `timers`,
`verify`

## Verifying

```bash
systemctl list-timers jengasec-backup.timer
sudo -u backup /usr/local/sbin/jengasec-backup      # run it by hand
ls -la /srv/backup/daily/
jengasec-restore --list
sudo journalctl -u jengasec-backup -n 50
```

Then the one that actually matters — prove a restore works before you need it:

```bash
sudo -u backup /usr/local/sbin/jengasec-backup-verify
```

Do this **once, by hand, before the competition**. Everything else in this role
is machinery around that single question.
