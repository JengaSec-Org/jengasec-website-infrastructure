# `common`

**Phase 1 · Implemented**

The foundation every other role assumes. Packages, hostname, timezone, locale,
time synchronisation, automatic security updates, and the shell environment.

Nothing else in this repository is safe to run before `common` has run.

## What it does

| Area | Detail |
|---|---|
| Packages | apt cache refresh with a TTL, safe upgrade, base toolkit, build toolchain |
| Identity | Sets the hostname and the matching `/etc/hosts` entry |
| Locale | Generates and sets `en_US.UTF-8` |
| Time | systemd-timesyncd against the Debian NTP pool |
| Updates | unattended-upgrades, **security pocket only**, no automatic reboot |
| Shell | MOTD, `/etc/profile.d/99-jengasec.sh`, `/etc/vim/vimrc.local` |

## Two details worth knowing

**The `/etc/hosts` entry is not cosmetic.** If the hostname does not resolve,
`sudo` pauses for about ten seconds on every invocation and Bind9 refuses to
start. It presents as "the server feels slow", which is a miserable thing to
debug.

**Changing the timezone restarts cron.** cron caches the offset at start, so
without the restart it keeps firing scheduled jobs on the old timezone — your
02:00 backup silently runs at the wrong hour.

## Variables

Full list in [`defaults/main.yml`](defaults/main.yml). The ones you are most
likely to change:

| Variable | Default | Notes |
|---|---|---|
| `common_timezone` | `Africa/Nairobi` | Must match `TIME_ZONE` in the platform's `config/settings.py` |
| `common_locale` | `en_US.UTF-8` | |
| `common_packages` | see defaults | Base toolkit for every host |
| `common_install_build_tools` | `true` | Needed by pip for `psycopg2` and `PyMuPDF` |
| `common_upgrade_packages` | `true` | Set `false` to freeze versions during the competition |
| `common_unattended_upgrades_security_only` | `true` | Do not widen this |
| `common_unattended_upgrades_auto_reboot` | `false` | Leave off — never reboot without a human |
| `common_ntp_servers` | Debian pool | Point at campus NTP if one exists |

## Example play

```yaml
- name: Base configuration
  hosts: infra
  become: true
  roles:
    - role: common
      tags: [common]
```

## Tags

`common`, `packages`, `hostname`, `locale`, `timezone`, `ntp`, `updates`,
`motd`, `shell`

Re-apply only the MOTD, for example:

```bash
ansible-playbook -i inventories/production playbooks/bootstrap.yml --tags motd
```

## Verifying

```bash
hostnamectl
timedatectl status
locale
systemctl status systemd-timesyncd
unattended-upgrades --dry-run --debug
```
