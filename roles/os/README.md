# `os`

**Phase 1 · Implemented**

Operating-system tuning: kernel parameters, resource limits, swap, journal size,
and the kernel module blacklist.

## What it does

| Area | File it writes |
|---|---|
| Kernel parameters | `/etc/sysctl.d/60-jengasec.conf` |
| PAM limits | `/etc/security/limits.d/60-jengasec.conf` |
| systemd limits | `/etc/systemd/system.conf.d/60-jengasec-limits.conf` |
| Journal caps | `/etc/systemd/journald.conf.d/60-jengasec.conf` |
| Module blacklist | `/etc/modprobe.d/60-jengasec-blacklist.conf` |
| Swap | `/swapfile` + an fstab entry |

## Three things worth knowing

**systemd services ignore `/etc/security/limits.conf`.** That is a PAM file, and
systemd services never go through PAM. Setting only the PAM limit and then
wondering why nginx still reports "too many open files" is a rite of passage —
the `system.conf.d` drop-in is what actually raises it.

**The journal cap is the most valuable setting here.** Debian defaults to 10% of
the filesystem. Uncapped logs filling the disk is the most common way a small
server dies quietly; the symptom looks like "PostgreSQL stopped accepting
writes" and the cause is a log directory.

**Blacklisting takes two lines per module.** `blacklist` stops automatic loading
on hardware detection; `install <name> /bin/true` stops an explicit `modprobe`.
Without the second, anything that can run modprobe can still load the module.

## Variables

Full list in [`defaults/main.yml`](defaults/main.yml), where every sysctl carries
its reasoning.

| Variable | Default | Notes |
|---|---|---|
| `os_sysctl` | ~35 keys | The base ruleset. Prefer overriding, not editing. |
| `os_sysctl_overrides` | `{}` | Merged **over** `os_sysctl` — set one key without restating the rest |
| `os_limits` | nofile 16384/32768, core 0 | |
| `os_swap_enabled` | `true` | |
| `os_swap_size_mb` | `2048` | `4096` on the 4 GB host |
| `os_journald_max_use` | `500M` | |
| `os_blacklist_modules` | 11 modules | Uncomment `usb-storage` for exposed machines |

Overriding a single sysctl, in `group_vars/database/main.yml`:

```yaml
os_sysctl_overrides:
  vm.swappiness: 1          # PostgreSQL must not be swapped out
  vm.overcommit_memory: 2
```

## Example play

```yaml
- name: OS tuning
  hosts: infra
  become: true
  roles:
    - role: os
      tags: [os]
```

## Tags

`os`, `sysctl`, `limits`, `modules`, `journal`, `swap`, `mounts`

## Verifying

```bash
sysctl -a --pattern 'vm.swappiness|net.ipv4.tcp_syncookies|kernel.kptr_restrict'
ulimit -n
cat /proc/$(pidof nginx | cut -d' ' -f1)/limits
journalctl --disk-usage
swapon --show
modprobe -n -v cramfs
lsmod | grep -E 'dccp|sctp|cramfs'
```

The last two should show the module refusing to load and nothing matching.

## Note on swap

Every swap task is guarded so a re-run never recreates or resizes an existing
swap file. Resizing would mean `swapoff` on a live server, which can trigger the
OOM killer on a box that was using it. To change the size, disable swap by hand
during a maintenance window, delete the file, then re-run.
