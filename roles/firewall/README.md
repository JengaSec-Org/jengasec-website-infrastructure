# `firewall`

**Phase 2 · Implemented**

UFW, with the ruleset expressed as data and three layers of protection against
locking yourself out.

## The ruleset is data

Rules come from three lists, merged by the role. Adding a port is an edit to
`group_vars` — never to a task.

| List | Lives in | Scope |
|---|---|---|
| `firewall_rules_common` | `group_vars/all` | Every host — SSH |
| `firewall_rules_group` | `group_vars/<group>` | Per function — 80/443, 5432, 53 |
| `firewall_rules_host` | `host_vars/<host>` | One machine |

```yaml
firewall_rules_group:
  - port: 5432
    proto: tcp
    from: "10.0.0.11"
    comment: "PostgreSQL — from the web host only"
```

Always write the `comment`. It shows up in `ufw status` and it is what tells the
next person whether a rule is still needed.

## Order matters, and it is the whole point of `tasks/main.yml`

1. Merge the rule lists
2. **Assert** SSH is among them — refuses to continue if not
3. Add the SSH rule **first**, explicitly
4. Add every other rule
5. Set default policies
6. **Only now** enable UFW

Enabling UFW with a default-deny policy before the SSH rule exists drops your
session mid-play and leaves the host unreachable. Steps 2 and 3 are why this
role is not four lines long.

Step 3 is deliberately redundant with the rule list. It costs one task and it
guarantees the SSH rule exists before `ufw enable` regardless of how anyone
reorders `group_vars` later.

There is a fourth check after enabling: the role reads back
`ufw status verbose` and asserts the SSH port really is in the live kernel
ruleset, rather than trusting that the earlier tasks did what they claimed.

## What the servers allow

| Group | Port | From |
|---|---|---|
| all | 22 | LAN |
| web | 80, 443 | anywhere |
| database | 5432, 6379 | **the web host only** |
| dns | 53 tcp+udp | LAN |
| dhcp | 67 udp | anywhere (broadcasts) |
| monitored | 9100 | the monitoring host only |

The database rule is the most important one here. PostgreSQL is not open to the
LAN — only server1 can reach it.

## Logging is `low`

`low` logs blocked packets only. `medium` and above log accepted traffic too,
which on a competition network fills the disk within hours and drowns the
entries you actually wanted.

## SSH rate limiting

`firewall_rate_limit_ssh: true` uses UFW's `limit` rule — drops a source that
opens more than 6 connections in 30 seconds. Worth having even with password
auth disabled, because it keeps the auth log readable by cutting off constant
background scanning.

Do **not** apply `limit` to a port serving real traffic: legitimate users behind
a single NAT address would trip it collectively.

## Variables

| Variable | Default |
|---|---|
| `firewall_enabled` | `true` |
| `firewall_default_incoming` | `deny` |
| `firewall_default_outgoing` | `allow` |
| `firewall_logging` | `low` |
| `firewall_rate_limit_ssh` | `true` |
| `firewall_require_ssh_rule` | `true` — **leave this on** |
| `firewall_reset_before_apply` | `false` |
| `firewall_ipv6` | `false` — must match `networking_ipv6_enabled` |

## `firewall_reset_before_apply`

Resets UFW and rebuilds the ruleset from this repository, removing anything
added by hand. That is the correct end state, but the reset briefly leaves the
host with no rules — so it is off by default. Use it deliberately, with console
access, when the live ruleset has drifted.

## Tags

`firewall`, `packages`, `rules`, `ssh`, `policy`, `logging`, `enable`,
`verify`, `reset`

## Verifying

```bash
sudo ufw status verbose
sudo ufw status numbered
sudo iptables -L -n -v
```

From another host, confirm the database really is closed:

```bash
nc -zv 10.0.0.12 5432   # from server1: should connect
nc -zv 10.0.0.12 5432   # from anywhere else: should time out
```

## If you are locked out

Console access, then:

```bash
sudo ufw disable
sudo ufw allow 22/tcp
sudo ufw enable
```

Then work out which rule was missing before running the role again.
