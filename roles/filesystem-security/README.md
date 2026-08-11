# `filesystem-security`

**Phase 3 · Implemented**

Ownership, permissions, ACLs, and the scans that surface what has drifted.

Unglamorous, and the reason a great many breaches escalate from "read one file"
to "own the machine".

## Enforced permissions

Debian ships these correctly. They drift when someone debugging a permission
problem at 2am runs `chmod 777` and forgets. Re-asserting them on every run is
exactly the kind of thing automation should be doing.

| File | Mode | Why it matters |
|---|---|---|
| `/etc/shadow` | `0640 root:shadow` | World-readable hands every password hash to any local account, and offline cracking is not hard |
| `/etc/passwd` | `0644` | |
| `/etc/ssh/sshd_config` | `0600` | |
| `/boot/grub/grub.cfg` | `0600` | Contains the boot password hash if one is set |
| `/etc/cron.*` | `0700` | A writable cron directory is a scheduled root shell |

## Cron restriction

`cron.allow` exists **without** a `cron.deny`. That specific combination is what
makes it restrictive — only the listed accounts may use `crontab` or `at`, and
everyone else is refused.

If `cron.deny` is ever recreated the semantics flip, which is why the role
removes it on every run.

## umask 027

Set in two places, because they cover different sessions: `login.defs` governs
login shells and `/etc/profile.d` covers interactive shells generally. Setting
only one leaves a gap that is tedious to find later.

Debian's default of `022` makes every new file world-readable — the wrong
default on a server holding competition submissions.

## ACLs, and `default: true`

The `deploy` account needs write access to the application tree without owning
it and without being added to the app group everywhere. That is what ACLs are
for: finer than group membership, and reversible.

The `default: true` flag is the part that matters. It sets the **default ACL**,
so files created later inherit it. Without it, the ACL covers what exists today
and every subsequent `git pull` produces files `deploy` cannot touch — which
presents as a deployment that worked last week and does not now.

## The scans report; they do not fix

| Scan | Looks for | Why report rather than fix |
|---|---|---|
| World-writable | Any local account can modify | Usually a mistake, occasionally load-bearing. Deleting one automatically would be worse than the problem. |
| Unowned | Files from a deleted account | UIDs get reused, so a new account can silently inherit the old owner's data |
| setuid/setgid | Privilege-bearing binaries | There is a known, stable set — the value is in the **diff** |

The setuid scan is the one to pay attention to. A stock Debian server has a
predictable list: `sudo`, `su`, `passwd`, `mount`, a handful of others. The
value is not the list but a **new entry appearing between two runs**, which is
why it runs on every play rather than once at build time. A setuid copy of
`bash` in `/tmp` is not subtle, and this is how you notice it.

## Variables

| Variable | Default |
|---|---|
| `filesystem_security_critical_files` | 10 files, see defaults |
| `filesystem_security_cron_dirs` | `/etc/cron.*` |
| `filesystem_security_restrict_cron` | `true` |
| `filesystem_security_cron_allowed_users` | `root`, `jengasec` |
| `filesystem_security_umask` | `027` |
| `filesystem_security_app_dirs` | app root, media, static, logs |
| `filesystem_security_acls` | `deploy` rwx on the source dir |
| `filesystem_security_scan_*` | all `true` |

## Tags

`filesystem-security`, `packages`, `permissions`, `cron`, `umask`,
`application`, `acl`, `scan`

## Verifying

```bash
ls -l /etc/shadow /etc/passwd /etc/ssh/sshd_config
ls -ld /etc/cron.*
getfacl /opt/jengasec/app
umask
```

Run the scans by hand:

```bash
sudo find / -xdev -type f -perm -0002 2>/dev/null
sudo find / -xdev \( -nouser -o -nogroup \) 2>/dev/null
sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort
```

Keep the setuid output from a known-good build and diff against it later — that
comparison is worth more than any single run of the scan.
