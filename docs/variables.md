# Variables

Where values live, which one wins, and what each key does.

## The rule

**No literal values in `tasks/main.yml`.** Package lists, ports, paths, users
and toggles all live in `defaults/main.yml`, namespaced by role. A task
references the variable; the value is defined somewhere you can find it.

## Precedence

Lowest to highest. Later layers override earlier ones.

| Layer | File | Holds |
|---|---|---|
| 1 | `roles/<role>/defaults/main.yml` | A safe default so the role runs standalone |
| 2 | `inventories/<env>/group_vars/all/main.yml` | Site-wide choices — domain, timezone, accounts |
| 3 | `inventories/<env>/group_vars/<group>/main.yml` | Per function — firewall rules, tuning |
| 4 | `inventories/<env>/host_vars/<host>.yml` | Per machine — address, interface, SANs |
| 5 | `--extra-vars` on the command line | One-off overrides. Wins over everything. |

The practical rule: **put a value at the least specific layer that is still
correct.** A timezone belongs in `group_vars/all`. An IP address belongs in
`host_vars`. Putting the timezone in `host_vars` three times means changing it
three times.

Inspect what a host actually resolved:

```bash
ansible-inventory -i inventories/production --host server1
```

## Merging, not replacing

Ansible **replaces** variables rather than merging them. Redefining a dict in
`group_vars` discards every key you did not restate.

Two places handle this explicitly:

**Sysctls** — the `os` role merges `os_sysctl_overrides` over `os_sysctl`, so a
group can change one key:

```yaml
# group_vars/database/main.yml
os_sysctl_overrides:
  vm.swappiness: 1
```

**Firewall rules** — three separate lists, concatenated by the role:

```
firewall_rules_common  (group_vars/all)     +
firewall_rules_group   (group_vars/<group>) +
firewall_rules_host    (host_vars/<host>)
```

That is why they are three variables rather than one.

---

## `group_vars/all/main.yml`

| Variable | Example | Notes |
|---|---|---|
| `jengasec_domain` | `jengasec.local` | Used by DNS, certificates, nginx |
| `jengasec_environment` | `production` | Colours the shell prompt |
| `jengasec_network_cidr` | `10.0.0.0/24` | Firewall trust, DNS ACL, DHCP subnet |
| `jengasec_network_gateway` | `10.0.0.1` | |
| `common_timezone` | `Africa/Nairobi` | **Must match the platform's `TIME_ZONE`** |
| `common_locale` | `en_US.UTF-8` | |
| `common_managed_banner` | — | Header stamped into every rendered file |
| `ssh_port` | `22` | Also feeds `ansible_port` and the firewall assert |
| `ssh_allow_groups` | `[sudo, jengasec]` | Only these may log in |
| `users_service_accounts` | list of dicts | See below |
| `users_admin_ssh_keys` | `[christine.pub]` | Files in `roles/users/files/ssh-keys/` |
| `firewall_rules_common` | list of dicts | Applied to every host |
| `app_*` | `/opt/jengasec/...` | Application paths, mirroring `settings.py` |

### `users_service_accounts`

```yaml
- name: deploy
  comment: "Application deployment account"
  groups: [jengasec]
  shell: /bin/bash          # /usr/sbin/nologin for daemons
  system: false             # true = UID < 1000, no ageing
  sudo_nopasswd: true
  sudo_commands:            # omit for full sudo; omit both for none
    - "/usr/bin/systemctl restart gunicorn"
  ssh_keys:                 # optional, per account
    - ci-deploy.pub
```

### `firewall_rules_*`

```yaml
- port: 5432                # or "6000:6010" for a range
  proto: tcp                # tcp | udp
  from: "10.0.0.11"         # CIDR, address, or "any"
  comment: "PostgreSQL — from the web host only"
  direction: in             # optional, defaults to in
```

Always write the comment. It appears in `ufw status` and it is what tells the
next person whether the rule is still needed.

---

## `group_vars/<group>/main.yml`

| Group | Key variables |
|---|---|
| `web` | `gunicorn_workers`, `django_allowed_hosts`, `django_db_*`, `ollama_*` |
| `database` | `postgresql_shared_buffers`, `postgresql_hba_entries`, `redis_maxmemory`, `os_sysctl_overrides` |
| `dns` | `dns_records`, `dns_reverse_records`, `dns_forwarders`, `dns_recursion_allowed_from` |
| `dhcp` | `dhcp_subnets`, `dhcp_reservations`, `dhcp_configure` |
| `backup` | `backup_sources`, `backup_retention_*`, `backup_encrypt` |
| `monitoring` | `prometheus_*`, `grafana_*`, `node_exporter_*` |
| `monitored` | node_exporter firewall rule |

### `dns_records`

```yaml
- { name: "platform", type: CNAME, value: "server1" }
- { name: "@",        type: A,     value: "10.0.0.12" }   # zone apex
```

### `dns_reverse_records`

```yaml
- { octet: "11", name: "server1.jengasec.local." }
```

The `octet` is the **last part only** — the zone name carries the network,
reversed. The target **must end with a dot**, or it silently becomes
`server1.jengasec.local.0.0.10.in-addr.arpa`.

---

## `host_vars/<host>.yml`

Machine-specific facts. Nothing here should be true of more than one host.

| Variable | Notes |
|---|---|
| `common_hostname` | FQDN |
| `host_role_description` | Shown in the MOTD |
| `networking_interface` | **Check with `ip -brief link show`** — rarely `eth0` |
| `networking_address` / `_netmask` / `_gateway` | |
| `networking_dns_servers` | |
| `os_swap_enabled` / `os_swap_size_mb` | |
| `certificates_common_name` | |
| `certificates_subject_alt_names` | What browsers actually validate |

---

## Secrets

Every secret is `vault_`-prefixed and lives in the encrypted `vault.yml`. See
[secrets.md](secrets.md). Never define one in `group_vars` or `host_vars`, even
temporarily — temporary files get committed.

## Variables that must agree

Getting these out of step causes failures that do not point at the cause:

| These | Must match |
|---|---|
| `common_timezone` | The platform's `TIME_ZONE` in `config/settings.py` — otherwise logs cannot be correlated |
| `ssh_port` | The firewall rule and `ansible_port`. The firewall role asserts this. |
| `networking_ipv6_enabled` | `firewall_ipv6`. Enabling one alone leaves an unfiltered address. |
| `gunicorn_bind` | `nginx_upstream_socket` |
| `app_media_dir` | The platform's `MEDIA_ROOT` |
| `django_db_host` | The database host's real address, and its `pg_hba` entry |

## Debugging

```bash
ansible-inventory -i inventories/production --host server1     # resolved vars
ansible -i inventories/production server1 -m ansible.builtin.debug -a "var=firewall_rules_common"
ansible-playbook -i inventories/production playbooks/bootstrap.yml --check --diff
```

If a variable is undefined at run time, it is almost always one of: a typo in
the name, defined in `host_vars` for a different host, or defined in a
`group_vars` directory whose name does not match a group in `hosts.yml`.
