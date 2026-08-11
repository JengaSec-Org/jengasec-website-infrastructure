# `security`

**Phase 3 · Implemented**

Host hardening, mapped to the CIS Debian 12 Benchmark.

This is the umbrella role. It applies host-level hardening directly and pulls in
three others through `meta/main.yml`:

- [`fail2ban`](../fail2ban/README.md) — intrusion prevention
- [`audit`](../audit/README.md) — auditd rules
- [`filesystem-security`](../filesystem-security/README.md) — permissions and ACLs

Running `security` runs all four.

## CIS item numbers are in the comments

Every task carries the benchmark item it implements. That is partly rigour and
partly the point of this repository: a club member reading the role can look up
exactly why a control exists rather than taking it on faith. For a cybersecurity
club, infrastructure that explains itself is worth more than infrastructure that
merely works.

## What it does

| Area | CIS | Detail |
|---|---|---|
| Password quality | 5.4.1 | 14 characters, 4 classes, dictionary check, applies to root |
| Password ageing | 5.5.1 | 90-day maximum, 14-day warning |
| Login policy | 5.5 | umask 027, SHA512, 4s fail delay |
| Banners | 1.7 | `/etc/issue` and `/etc/issue.net`, no OS version disclosed |
| `su` restriction | 5.6 | `pam_wheel` — sudo group only |
| Core dumps | 1.5.1 | systemd coredump handler disabled |
| Ctrl-Alt-Del | 1.4.3 | Target masked |
| AppArmor | 1.6 | Enabled, profiles in **enforce** mode |
| Packages | 2.2 | telnet, rsh, talk, nis, xinetd removed |
| `/dev/shm` | 1.1.x | `noexec,nosuid,nodev` |
| Process accounting | — | `acct` — full command history |

## Deliberately not here

To avoid two roles fighting over one file:

| Concern | Owned by |
|---|---|
| sysctl, kernel module blacklist | [`os`](../os/README.md) |
| sshd configuration | [`ssh`](../ssh/README.md) |
| sudo policy | [`users`](../users/README.md) |
| Firewall rules | [`firewall`](../firewall/README.md) |

## Two honest exceptions

**Compilers are not restricted.** `security_restrict_compilers: false`. The
`common` role installs `build-essential` because pip needs it to compile
psycopg2 and PyMuPDF. Removing compilers would break deployment. This is a
documented trade rather than a silent gap — if the club later ships wheels
instead of building on the server, revisit it.

**AppArmor profiles are enforced, which can break things.** Complain mode logs a
violation and allows it, which is useful while writing a profile and worthless
as a control. If a service misbehaves after this role runs, check
`journalctl | grep apparmor` before assuming the service is at fault.

## The two checks at the end

The role ends by failing loudly on two conditions that should never be true:

**Empty passwords.** An account with an empty password field can be logged into
with no credential at all.

**A second UID 0.** UID 0 *is* root — an account with UID 0 under a different
name has full root privileges and does not look unusual in a user listing. It is
a classic persistence trick rather than a configuration mistake, so the role
treats it as an incident and stops.

## Variables

| Variable | Default |
|---|---|
| `security_password_min_length` | `14` |
| `security_password_max_days` | `90` |
| `security_login_defs_umask` | `027` |
| `security_restrict_su` | `true` |
| `security_su_group` | `sudo` |
| `security_disable_coredumps` | `true` |
| `security_apparmor_enforce_profiles` | `true` |
| `security_remove_packages` | telnet, rsh-client, talk, nis, … |
| `security_restrict_compilers` | `false` — see above |

## Tags

`security`, `packages`, `passwords`, `login`, `banners`, `su`, `coredumps`,
`console`, `mounts`, `apparmor`, `accounting`, `verify`

## Verifying

```bash
sudo grep -E '^(PASS_MAX_DAYS|UMASK|ENCRYPT_METHOD)' /etc/login.defs
sudo grep -E '^(minlen|minclass)' /etc/security/pwquality.conf
sudo aa-status
mount | grep /dev/shm
systemctl is-enabled ctrl-alt-del.target      # expect "masked"
sudo awk -F: '($2 == "") { print $1 }' /etc/shadow      # expect no output
sudo awk -F: '($3 == 0) { print $1 }' /etc/passwd       # expect only "root"
```

For a fuller picture, `lynis audit system` is worth running once after Phase 3
and keeping the score as a baseline.
