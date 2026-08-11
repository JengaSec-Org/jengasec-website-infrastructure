# Pre-deployment review

**Read this before running Ansible against real hardware.**

What this scaffold will do to your servers, what you must configure first, and
where it can go wrong. Everything here is checkable against the repository — if
something below does not match the code, the code wins and this document is a
bug.

---

## 1. What this is, and what it is not

**16 of 30 roles are implemented.** They cover Phases 1–3:

| Phase | Roles | Result |
|---|---|---|
| 1 — Base OS | `common`, `os`, `users`, `ssh`, `python`, `git`, `systemd` | A consistent, hardened Debian baseline |
| 2 — Networking | `networking`, `firewall`, `dns`, `dhcp`, `certificates` | Addressing, UFW, Bind9, internal CA |
| 3 — Security | `security`, `fail2ban`, `audit`, `filesystem-security` | CIS-mapped hardening, auditd, intrusion prevention |

> ### The JengaSec platform is NOT deployed by this scaffold
>
> The 14 roles that would install PostgreSQL, nginx, gunicorn, Django, and Redis
> are **stubs**. They raise an error rather than pretending to work.
>
> After running everything here you will have three well-configured, hardened
> Debian servers with **no application on them**. That is the intended end state
> of this phase — but "infrastructure" invites the assumption that the app comes
> with it, so it is worth being explicit.

Stubs fail loudly on purpose. A green Ansible run that changed nothing is the
most expensive bug in infrastructure code: you believe a machine is configured
when it is not, and you find out during the event.

---

## 2. What happens to each server

| | server1 | server2 | server3 |
|---|---|---|---|
| **Function** | Web — nginx, gunicorn, Django | Database + DNS/DHCP | Backup + monitoring |
| **RAM** | 8 GB | 4 GB | — |
| **Groups** | `infra`, `web`, `monitored` | `infra`, `database`, `dns`, `dhcp`, `monitored` | `infra`, `backup`, `monitoring`, `monitored` |
| **Phase 1** | ✅ all 7 roles | ✅ all 7 roles | ✅ all 7 roles |
| **Phase 2** | firewall, certificates | firewall, certificates, **Bind9** | firewall, certificates |
| **Phase 3** | ✅ all 4 roles | ✅ all 4 roles | ✅ all 4 roles |
| **Swap created** | 2 GB | 4 GB | 2 GB |
| **Extra tuning** | — | `vm.swappiness=1` so PostgreSQL is never swapped out | disk warning at 75% |

### Ports opened

Every rule carries a source restriction. `any` appears only where it must.

| Port | server1 | server2 | server3 | Purpose |
|---|---|---|---|---|
| 22 | LAN | LAN | LAN | SSH, rate-limited |
| 80 / 443 | **any** | — | — | The public platform |
| 53 tcp+udp | — | LAN | — | DNS |
| 67 udp | — | any¹ | — | DHCP (broadcasts) |
| 5432 | — | **server1 only** | — | PostgreSQL |
| 6379 | — | **server1 only** | — | Redis |
| 9100 | server3 only | server3 only | server3 only | node_exporter |
| 3000 / 9090 | — | — | LAN | Grafana / Prometheus |
| 873 | — | — | LAN | rsync backup ingest |

¹ Only if you enable DHCP, which is off by default.

**The 5432 rule is the most important one in the repository.** PostgreSQL is not
reachable from the LAN — only from the web host.

### Services

**Enabled:** `ssh`, `ufw`, `fail2ban`, `auditd`, `apparmor`, `acct`,
`systemd-timesyncd`, `cron`, `systemd-journald`, plus `named` on server2.

**Disabled and stopped:** `bluetooth`, `cups`, `cups-browsed`, `avahi-daemon`,
`ModemManager` — and their sockets separately, because a disabled service with
an enabled socket still starts on first connection.

---

## 3. Every file created or modified

About 50 files. Grouped by the role that owns them.

> **Three roles replace a file wholesale** rather than adding a drop-in:
> `ssh` (`/etc/ssh/sshd_config`), `dns` (`named.conf.*` and the zone files), and
> `dhcp` (`dhcpd.conf`). **Any hand-edit to those files is destroyed on the next
> run.** All three keep timestamped backups. Everything else is a drop-in that
> leaves the distribution's original config in place underneath.

### `common`

| Path | What |
|---|---|
| `/etc/hostname` (via `hostnamectl`) | Sets the hostname |
| `/etc/hosts` | `127.0.1.1` entry — without it `sudo` hangs ~10s and Bind9 refuses to start |
| `/etc/default/locale` | `en_US.UTF-8` |
| `/etc/systemd/timesyncd.conf` | NTP servers |
| `/etc/apt/apt.conf.d/50unattended-upgrades` | Security patches only, no auto-reboot |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Daily schedule |
| `/etc/motd` | JengaSec banner |
| `/etc/profile.d/99-jengasec.sh` | Shell aliases, history, env-coloured prompt |
| `/etc/vim/vimrc.local` | 2-space indent, no tabs |
| `/etc/update-motd.d/10-uname` | Removed — hides the OS version |

### `os`

| Path | What |
|---|---|
| `/etc/sysctl.d/60-jengasec.conf` | ~35 kernel parameters: network hardening, `kptr_restrict`, `swappiness` |
| `/etc/security/limits.d/60-jengasec.conf` | nofile 16384/32768, core dumps off |
| `/etc/systemd/system.conf.d/60-jengasec-limits.conf` | The limits that actually apply to services |
| `/etc/systemd/journald.conf.d/60-jengasec.conf` | Journal capped at 500 MB |
| `/etc/modprobe.d/60-jengasec-blacklist.conf` | 11 modules blocked — cramfs, dccp, sctp, … |
| `/swapfile` + fstab entry | Swap, mode 0600 |

### `users`

| Path | What |
|---|---|
| `/etc/sudoers.d/10-jengasec-defaults` | Logging, 5-min timeout, `env_reset` |
| `/etc/sudoers.d/50-<account>` | Per-account policy, validated with `visudo -cf` |
| `/home/<account>/.ssh/authorized_keys` | Your public keys |

Creates `jengasec`, `deploy`, `backup`, `monitoring`.

### `ssh`

| Path | What |
|---|---|
| **`/etc/ssh/sshd_config`** | **Replaced.** Key-only, no root, `MaxAuthTries 3`, modern ciphers, `LogLevel VERBOSE` |
| `/etc/issue.net` | Pre-authentication banner |
| `/etc/ssh/ssh_host_ed25519_key` | Generated if absent |

### `python`, `git`, `systemd`

| Path | What |
|---|---|
| `/etc/pip.conf` | Index URL, timeouts |
| `/etc/gitconfig` | `autocrlf=input`, `fsckObjects`, `safe.directory` |
| `/etc/systemd/system.conf.d/50-jengasec.conf` | Timeouts, accounting, `TasksMax` |
| `/etc/systemd/system/default.target` | → `multi-user.target` |

### `networking` *(off by default)*

| Path | What |
|---|---|
| `/etc/network/interfaces.d/50-jengasec.cfg` | Static address |
| `/etc/network/interfaces` | One `source` line added |
| `/etc/resolv.conf` | Nameservers |
| `/etc/hosts` | Static entries for the other servers, so a DNS outage is not an app outage |
| `/etc/sysctl.d/61-jengasec-ipv6.conf` | IPv6 disabled |

### `firewall`, `certificates`

| Path | What |
|---|---|
| `/etc/default/ufw` | IPv6 setting |
| UFW ruleset | Default deny in, allow out |
| `/etc/ssl/jengasec/ca/jengasec-ca.{key,crt}` | The CA — **key on server1 only**, mode 0400 |
| `/etc/ssl/jengasec/<host>.crt` | Host certificate |
| `/etc/ssl/jengasec/<host>-fullchain.crt` | Cert + CA, for nginx |
| `/etc/ssl/jengasec/private/<host>.key` | Private key, mode 0400 |
| `/usr/local/share/ca-certificates/jengasec-ca.crt` | Added to the system trust store |

### `dns` *(server2)*

| Path | What |
|---|---|
| **`/etc/bind/named.conf.options`** | **Replaced.** Recursion limited to LAN, transfers refused, rate limiting |
| **`/etc/bind/named.conf.local`** | **Replaced.** Zone declarations |
| **`/var/lib/bind/db.jengasec.local`** | **Replaced.** Forward zone |
| **`/var/lib/bind/db.0.0.10.in-addr.arpa`** | **Replaced.** Reverse zone |
| `/var/log/named/` | Log directory |

### `security`, `fail2ban`, `audit`, `filesystem-security`

| Path | What |
|---|---|
| `/etc/security/pwquality.conf` | 14 chars, 4 classes, applies to root |
| `/etc/login.defs` | 7 keys edited — ageing, umask 027, SHA512 |
| `/etc/pam.d/su` | `pam_wheel` — su restricted to sudo group |
| `/etc/issue`, `/etc/issue.net` | Legal banners |
| `/etc/systemd/coredump.conf.d/60-jengasec.conf` | Core dumps off |
| `/dev/shm` mount | `noexec,nosuid,nodev` |
| `/etc/fail2ban/jail.local` | sshd + nginx jails, UFW ban action |
| `/etc/audit/auditd.conf` | 50 MB × 10 logs |
| `/etc/audit/rules.d/50-jengasec.rules` | ~40 rules incl. submission-data watches |
| `/etc/cron.allow`, `/etc/at.allow` | Only root and `jengasec` may schedule |
| `/etc/profile.d/00-jengasec-umask.sh` | umask 027 |
| Permissions on `/etc/shadow`, `/etc/passwd`, `/boot/grub/grub.cfg`, `/etc/cron.*` | Enforced every run |

---

## 4. Packages

**Installed — about 50:**

| Group | Count | Notable |
|---|---|---|
| Base toolkit | 22 | curl, vim, htop, rsync, dnsutils, tcpdump, jq, acl, sudo |
| Build tools | 7 | build-essential, libpq-dev — pip needs these for psycopg2 and PyMuPDF |
| Python | 7 | python3 (3.11), pip, venv, dev headers |
| Bind9 | 4 | server2 only |
| Security | 7 | fail2ban, auditd, apparmor, libpam-pwquality, acct |
| Certificates | 3 | openssl, python3-cryptography |

**Removed — 8:** `telnet`, `rsh-client`, `talk`, `ldap-utils`, `nis`, `xinetd`,
`avahi-daemon`, `prelink`. Cleartext protocols and listening daemons with no
role here. Most will not be installed on a minimal Debian; the task does not
fail if they are absent.

---

## 5. Configuration checklist

**41 values need replacing before the first production run.** Find them all:

```bash
grep -rn "TODO: replace" inventories/production/
```

That returns 43 lines — two are comment-box text in `hosts.yml`, not values.

### `inventories/production/hosts.yml` — 5 values

- [ ] `ansible_host` for server1, server2, server3 — the real addresses
- [ ] `ansible_user` — the account you can already SSH in as on a fresh install
- [ ] `ansible_ssh_private_key_file` — path to your private key

### `inventories/production/host_vars/server1.yml` — 5 · `server2.yml` — 4 · `server3.yml` — 5

- [ ] `networking_interface` — **see the warning below**
- [ ] `networking_address`, `networking_netmask`
- [ ] `networking_dns_servers` — server2's address
- [ ] `certificates_subject_alt_names` — the `IP:` entry

> **`networking_interface` is the one people get wrong.** Debian 12 uses
> predictable names — `ens18`, `enp0s3`, `eno1` — and it is **rarely `eth0`**.
> Applying a config to an interface that does not exist takes the machine off
> the network with no error at apply time. Check on the box:
>
> ```bash
> ip -brief link show
> ```
>
> The role asserts the interface exists before writing anything, so a wrong name
> fails the play rather than the server. Still worth getting right first.

### `inventories/production/group_vars/all/main.yml` — 4 values

- [ ] `jengasec_domain` — keep `jengasec.local`, or use a real domain
- [ ] `jengasec_network_cidr` — the competition LAN
- [ ] `jengasec_network_gateway`
- [ ] `users_admin_ssh_keys` — your key's filename

### `inventories/production/group_vars/dns/main.yml` — 11 values

- [ ] `dns_forwarders` — campus resolvers if they exist
- [ ] `dns_reverse_zone` and `dns_reverse_prefix` — must match your CIDR
- [ ] `dns_records` — five A records
- [ ] `dns_reverse_records` — three PTR records

Two rules that cost people an afternoon each:

- **PTR targets must end with a dot**, or `server1.jengasec.local` silently
  becomes `server1.jengasec.local.0.0.10.in-addr.arpa`.
- **The reverse `octet` is the last part only** — `10.0.0.11` is written `11`.

### `inventories/production/group_vars/dhcp/main.yml` — 6 values

Only if you enable DHCP. **Read [`roles/dhcp/README.md`](../roles/dhcp/README.md)
first** — a second DHCP server on a shared network breaks it for every device on
the segment.

### `inventories/production/group_vars/backup/main.yml` — 1 value

- [ ] `backup_gpg_recipient` — for a Phase 10 stub, so this can wait

### Two more things, not marked TODO but still required

- [ ] **An SSH public key** in `roles/users/files/ssh-keys/`, with the filename
      listed in `users_admin_ssh_keys`. The `users` role **refuses to run**
      without one, because the `ssh` role that follows disables password
      authentication.
- [ ] **`vault.yml`** created from `vault.yml.example` and encrypted. See
      [`secrets.md`](secrets.md).

---

## 6. The switches

Twelve variables decide how much this actually does. These are the defaults.

| Switch | Default | Why |
|---|---|---|
| `networking_configure` | `false` | Reconfigures the interface you are connected over. If the installer already gave you working static addresses, leaving this off permanently is a reasonable choice. |
| `dhcp_configure` | `false` | A second authoritative DHCP server breaks a shared LAN for **every** device on it |
| `firewall_enabled` | `true` | |
| `firewall_require_ssh_rule` | `true` | Refuses to enable UFW unless SSH is permitted. **Leave this on.** |
| `audit_immutable` | `false` | Turn on before the competition — needs a reboot, so painful during setup |
| `users_ssh_exclusive` | `false` | Turn on once every member's key is committed; then removes any key not in the repo |
| `certificates_provider` | `internal_ca` | No public CA will ever issue for a `.local` name |
| `certificates_letsencrypt_staging` | `true` | The production endpoint rate-limits failures — debugging against it locks you out for a week |
| `fail2ban_django_enabled` | `false` | Needs a Django-side change first; see [`roles/fail2ban/README.md`](../roles/fail2ban/README.md) |
| `python_build_from_source` | `false` | Debian's 3.11 runs Django 5 fine |
| `security_restrict_compilers` | `false` | pip needs them for psycopg2 and PyMuPDF |
| `networking_ipv6_enabled` / `firewall_ipv6` | `false` | **Must be changed together** — one alone leaves an unfiltered address |

Reasoning for each is in [`decisions.md`](decisions.md).

---

## 7. Where it can go wrong

Three roles can end the SSH session you are running from. Each has guards; know
the recovery anyway.

### `ssh` — disables password authentication

**Guards:** refuses to run if no key is installed · `sshd -t` validates the
config *before* it replaces the live file · reloads rather than restarts ·
verifies the port answers afterwards · keeps timestamped backups.

```bash
ls -t /etc/ssh/sshd_config.*
sudo cp /etc/ssh/sshd_config.<timestamp> /etc/ssh/sshd_config
sudo systemctl reload ssh
```

### `firewall` — default deny inbound

**Guards:** asserts SSH is in the merged ruleset before doing anything · applies
the SSH rule *first*, before enabling · re-reads the live kernel ruleset
afterwards and asserts SSH is really there.

```bash
sudo ufw disable && sudo ufw allow 22/tcp && sudo ufw enable
```

### `networking` — reconfigures your interface

**Guards:** off by default · asserts address, gateway and DNS are all set ·
asserts the interface exists · reconfigures one interface rather than restarting
all networking · pings the gateway afterwards.

```bash
sudo ifdown eth0 --force
sudo mv /etc/network/interfaces.d/50-jengasec.cfg /root/
sudo ifup eth0
```

### And one that surprises people

**fail2ban can ban you** if `fail2ban_ignoreip` does not cover the address you
connect from. One mistyped password is enough.

```bash
sudo fail2ban-client set sshd unbanip <your-address>
```

> **Have console access open** — physical, iDRAC/iLO, or the hypervisor console —
> before running Phase 2. Not "available if needed". Open.

---

## 8. Order of operations

Full commands in [`runbook.md`](runbook.md).

```
0. python tests/structure-check.py        on Windows, before copying anything
1. copy to the Debian box, install ansible-core + collections
2. fill in the 41 TODO values
3. create vault.yml, add your SSH key
4. ./scripts/preflight.sh
5. dry run against the development inventory
6. Phase 1 — bootstrap        server3 → server2 → server1
7. Phase 3 — security         server3 → server2 → server1
8. Phase 2 — networking       server3 → server2 → server1   ← console open
9. before the competition: audit_immutable + users_ssh_exclusive, then reboot
```

**Two rules:**

**Run every phase twice.** The second run must report **zero changed tasks**.
That is the pass criterion for this entire scaffold — a run that keeps changing
things is not describing the system, it is fighting it, and you lose the ability
to tell a real change from noise.

**server1 last, every time.** It is the host you most need reachable, and by
then you will have made the same change twice already.

---

## 9. What is deliberately not done

Fourteen roles are stubs. Each has a README describing its intent and a
`defaults/main.yml` defining its variable contract, so `group_vars` written today
keeps working when the tasks are filled in.

| Phase | Roles |
|---|---|
| 4 — Platform | `nginx`, `gunicorn`, `django`, `redis` |
| 5 — Database | `postgresql` |
| 6 — HA | `loadbalancer` |
| 7 — Operations | `monitoring`, `logging`, `deployment`, `cron` |
| 8 — Storage | `storage`, `minio` |
| 9 — Public access | `cloudflare` |
| 10 — Continuity | `backup` |

**Suggested order when you continue** — not the same as the phase numbers, this
is what unblocks the most work next:

1. `postgresql` — nothing in Phase 4 is useful without it
2. `gunicorn` → `django` → `nginx`, in that order, so nginx never proxies to a
   socket that does not exist
3. `backup` — before the platform holds data anyone would miss
4. `monitoring`, `logging` — you want these before the event, not after

House rules for implementing one are in [`roles.md`](roles.md).

---

## Quick reference

```bash
# Validate the repo (no Ansible needed — works on Windows)
python tests/structure-check.py

# Find everything unconfigured
grep -rn "TODO: replace" inventories/production/

# Check interface names, on the target
ip -brief link show

# Preflight, then dry run
./scripts/preflight.sh
ansible-playbook -i inventories/development playbooks/bootstrap.yml \
    --check --diff --connection=local

# Deploy one phase to one host
make bootstrap LIMIT=server3

# Verify
sudo ufw status verbose
sudo fail2ban-client status
sudo auditctl -l | wc -l
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication)'
```
