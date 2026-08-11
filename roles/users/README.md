# `users`

**Phase 1 · Implemented**

Service accounts, groups, SSH keys, and sudo policy.

> **This role must run before `ssh`.** The `ssh` role disables password
> authentication. If no key has been installed first, the next connection fails
> and the host is unreachable. `playbooks/bootstrap.yml` enforces the order.

## Accounts it creates

| Account | Shell | Purpose |
|---|---|---|
| `jengasec` | bash | Administrator. Receives `users_admin_ssh_keys`. |
| `deploy` | bash | Application deployment. Restricted sudo — may restart gunicorn and nginx, nothing else. |
| `backup` | nologin | Backup service account. |
| `monitoring` | nologin | node_exporter. |

Defined in `group_vars/all/main.yml`, not here — adding an account is a data
edit.

## Safety measures

**It refuses to run without an admin key.** If `users_admin_ssh_keys` is empty
and `users_lock_passwords` is true, the role stops with an explanation rather
than creating a passwordless, keyless account and handing the host to the `ssh`
role.

**`/etc/sudoers` is never edited.** Every rule is a separate file in
`/etc/sudoers.d/`, and each one passes `visudo -cf` *before* it is moved into
place. A syntax error in sudoers means nobody can become root on a machine you
may only be able to reach over SSH.

**Restricted sudo uses full paths.** A bare command name would let anyone who
can write to a directory earlier in `PATH` substitute their own binary and have
it run as root.

**`requiretty` is deliberately not set.** It is a common hardening
recommendation and it would break this repository — Ansible's pipelining runs
tasks with no TTY, so `requiretty` makes every `become: true` task fail. The
template says so at the point where you would otherwise add it.

## SSH keys

Public keys go in [`files/ssh-keys/`](files/ssh-keys/README.md) — see that
README for naming and for how to check you have not grabbed a private key by
mistake.

**Removing a key does not revoke it.** `authorized_key` only adds, so a deleted
`.pub` file leaves the key on the server. Once every current member's key is
committed, set:

```yaml
users_ssh_exclusive: true
```

From then on this repository is the single source of truth, and any key added by
hand is removed on the next run — which is what you want, because an SSH key
nobody can account for is exactly what a persistent intruder leaves behind.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `users_service_accounts` | one admin | List of dicts; set in `group_vars` |
| `users_admin_ssh_keys` | `[]` | Filenames in `files/ssh-keys/` |
| `users_admin_account` | `jengasec` | Who receives those keys |
| `users_ssh_exclusive` | `false` | Turn on once the key list is complete |
| `users_lock_passwords` | `true` | Key-only login; sudo still works |
| `users_sudo_io_logging` | `false` | Full session capture — large on disk |
| `users_absent` | `[]` | Accounts to remove; home directories are kept |

### Account fields

```yaml
- name: deploy
  comment: "Application deployment account"
  groups: [jengasec]
  shell: /bin/bash
  system: false
  sudo_nopasswd: true
  sudo_commands:
    - "/usr/bin/systemctl restart gunicorn"
  ssh_keys:
    - ci-deploy.pub
```

Omit `sudo_commands` for full sudo. Omit both `sudo_*` keys for no sudo at all.

## Tags

`users`, `groups`, `accounts`, `ssh-keys`, `sudo`

## Verifying

```bash
getent passwd jengasec deploy backup monitoring
sudo -l -U deploy
sudo visudo -c
ls -l /etc/sudoers.d/
sudo cat /home/jengasec/.ssh/authorized_keys
```

`sudo -l -U deploy` should list only the systemctl commands. If it prints
`(ALL : ALL) ALL`, the restriction did not apply — check the account definition
in `group_vars`.
