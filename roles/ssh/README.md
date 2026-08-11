# `ssh`

**Phase 1 · Implemented**

Hardened OpenSSH server configuration.

> **This is the role that locks people out.** A mistake here does not produce an
> error message — it produces a machine you cannot reach, which on a rack in a
> locked room means a physical trip. Read this page before running it the first
> time.

## The five guards

Every one of these exists because of a specific way people lock themselves out.

1. **No key, no lockdown.** The role checks
   `/home/jengasec/.ssh/authorized_keys` exists and is non-empty before it will
   disable password authentication. Running `ssh` without `users` stops here.
2. **Port change warning.** Moving off 22 prints the required order — firewall
   first, sshd second, verify third, close 22 last.
3. **`validate: sshd -t -f %s`.** The candidate config is parsed *before* it
   replaces the live file. If the template produced anything sshd rejects, the
   task fails and `/etc/ssh/sshd_config` is untouched. This one line is the
   difference between a failed play and a dead server.
4. **Reload, not restart.** `reload` keeps the listening socket and existing
   sessions, including the one Ansible is running over.
5. **Verify after.** The role waits for the port to answer and prints the
   effective settings from `sshd -T`, while your session is still open.

## What it configures

| Setting | Value | Why |
|---|---|---|
| `PasswordAuthentication` | `no` | The single most valuable line. Makes password brute-forcing structurally impossible. |
| `PermitRootLogin` | `no` | Not `prohibit-password` — a root login is anonymous, and you lose the record of who did it. |
| `MaxAuthTries` | `3` | |
| `AllowGroups` | `sudo jengasec` | A new account is inert until it joins one |
| `ClientAliveInterval` | `300` × 3 | 15-minute idle disconnect |
| `AllowAgentForwarding` | `no` | With it on, whoever controls this box can use your key elsewhere |
| `LogLevel` | `VERBOSE` | Logs the key fingerprint — without it you know *which account*, not *which person* |
| Ciphers / KEX / MACs | modern only | Old clients will fail to connect; that is the trade |

## The config file is authoritative

The template writes a complete `/etc/ssh/sshd_config` with **no**
`Include /etc/ssh/sshd_config.d/*.conf`. Everything sshd does is in one file.

If that directory contains leftovers from a cloud image, the role reports them
during the run — it does not delete another package's files, but it tells you
they are now dead config so nobody wastes time reading them later.

## Changing the port

The order is fixed:

```bash
# 1. Open the new port while 22 is still open
ansible-playbook -i inventories/production playbooks/networking.yml --tags firewall

# 2. Move sshd
ansible-playbook -i inventories/production playbooks/bootstrap.yml --tags ssh

# 3. From a SECOND terminal, prove it works — do not skip this
ssh -p 2222 jengasec@server1

# 4. Only now remove the port 22 rule and re-run the firewall role
```

Doing 2 before 1 locks you out. Set `ssh_port` in `group_vars/all/main.yml`;
`hosts.yml` already passes it to `ansible_port`.

## Variables

Full list with reasoning in [`defaults/main.yml`](defaults/main.yml).

| Variable | Default |
|---|---|
| `ssh_port` | `22` |
| `ssh_password_authentication` | `false` |
| `ssh_permit_root_login` | `"no"` |
| `ssh_allow_groups` | `[sudo, jengasec]` |
| `ssh_max_auth_tries` | `3` |
| `ssh_client_alive_interval` | `300` |
| `ssh_log_level` | `VERBOSE` |
| `ssh_regenerate_host_keys` | `false` |
| `ssh_verify_after_change` | `true` |

## Tags

`ssh`, `banner`, `hostkeys`, `config`, `service`, `verify`

## Verifying

```bash
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries|loglevel)'
sudo systemctl status ssh
sudo ss -tlnp | grep sshd
```

Then, **from another machine**, before you close your session:

```bash
ssh -v jengasec@server1
```

The verbose output should show `Authenticated ... using publickey`.

## If you are locked out

1. Console access — physical, iDRAC/iLO, or the hypervisor console.
2. Log in as a local account and check `journalctl -u ssh -n 50`.
3. The role keeps a timestamped backup of every previous config
   (`backup: true`). Restore it:
   ```bash
   ls -t /etc/ssh/sshd_config.*
   sudo cp /etc/ssh/sshd_config.<timestamp> /etc/ssh/sshd_config
   sudo systemctl reload ssh
   ```
4. If the firewall is the cause: `sudo ufw status`, then
   `sudo ufw allow 22/tcp`.
