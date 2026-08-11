# `audit`

**Phase 3 · Implemented**

auditd — kernel-level records of who ran what, who read which file, and who
changed a permission.

This is the log you want to have been collecting **before** an incident, because
it cannot be reconstructed afterwards. For a cybersecurity club it is also the
most directly useful role here: the audit log is what a blue team actually reads
during an exercise.

## Reading the log

Every rule carries a `-k` key, which is what makes the log searchable:

```bash
sudo ausearch -k jengasec_identity -i     # -i decodes numeric IDs to names
sudo ausearch -k jengasec_privesc -i -ts today
sudo aureport --summary
sudo aureport -au                          # authentication attempts
```

A rule without a key still records, but finding it later means reading raw audit
output — which nobody does twice.

| Key | Catches |
|---|---|
| `jengasec_identity` | Account and group changes, `passwd`, `useradd` |
| `jengasec_privesc` | setuid execution, failed permission attempts |
| `jengasec_sudo` | sudo use and sudoers changes |
| `jengasec_config` | `/etc`, sshd_config, network, systemd |
| `jengasec_delete` | Deletions and renames by real users |
| `jengasec_perm` | chmod, chown, xattr changes |
| `jengasec_modules` | Kernel module loading |
| `jengasec_time` | Clock changes |
| `jengasec_mount` | Device mounts |
| **`jengasec_appdata`** | **Submission and judging data** |

## The rules that matter most for JengaSec

`audit_watch_application` watches the submission media directory and the Django
config. Reading a submission before the deadline, or altering a score after it,
is exactly the kind of thing this competition exists to detect — and those paths
hold the evidence.

`jengasec_modules` is the other one worth understanding: loading a kernel module
is how a rootkit arrives, and there is no legitimate reason for it to happen on
these servers after provisioning. Any hit on that key is worth investigating.

## The `auid` filters are not optional

Most syscall rules carry `-F auid>=1000 -F auid!=unset`. That restricts them to
logged-in humans and excludes daemons with no login session.

Without both filters these rules produce enormous volume — and what happens next
is that someone disables the one rule most worth having, because it is drowning
everything else.

## Immutable mode

`audit_immutable: false` by default.

Setting `-e 2` makes the ruleset immutable: no rule can be added, removed, or
changed until the machine reboots, including by root. That is the correct end
state, because an attacker with root can otherwise simply turn off the logging
that would record what they do next.

It is off during development because every rule change then needs a reboot.
**Turn it on before the competition** as a deliberate step:

```yaml
audit_immutable: true
```

then run the role and reboot. The flag is written to
`99-jengasec-immutable.rules` rather than at the end of the main rules file,
because the kernel refuses every rule that comes after it — a later rule file
would be silently ignored.

Once immutable, `augenrules --load` fails until reboot. The role detects that
and reports it instead of failing the play.

## Two deliberate trade-offs

Both are places where the strict answer would take the competition platform down
mid-event. Both are documented at the point where they are made:

| Setting | Strict answer | Ours | Why |
|---|---|---|---|
| `-f` on buffer overflow | `2` (kernel panic) | `1` (printk) | A burst of audit events should not halt the server; the kernel log still records that events were lost |
| `disk_full_action` | `halt` | `rotate` | A full disk becomes a total outage; we lose the oldest history instead |

If this were a system of record rather than a competition platform, both would
go the other way.

## Variables

| Variable | Default |
|---|---|
| `audit_buffer_size` | `8192` |
| `audit_failure_mode` | `1` |
| `audit_max_log_file_mb` | `50` |
| `audit_num_logs` | `10` (~500 MB) |
| `audit_disk_full_action` | `rotate` |
| `audit_immutable` | `false` |
| `audit_watch_*` | all `true` |
| `audit_application_paths` | media dir, config dir |

## Tags

`audit`, `packages`, `config`, `rules`, `service`, `verify`

## Verifying

```bash
sudo auditctl -l | wc -l          # rule count — must not be 0
sudo auditctl -s                  # daemon status, buffer, lost events
sudo ausearch -k jengasec_identity -i -ts recent
```

The role fails the play if `auditctl -l` reports no rules: auditd running with
nothing loaded is the worst outcome, because you pay for the daemon and collect
no evidence.

Generate a test event:

```bash
sudo touch /etc/passwd
sudo ausearch -k jengasec_identity -i -ts recent | tail -20
```

Check for dropped events after a busy period — a non-zero `lost` means
`audit_buffer_size` is too small:

```bash
sudo auditctl -s | grep lost
```
