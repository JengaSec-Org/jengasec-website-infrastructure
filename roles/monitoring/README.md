# `monitoring`

**Phase 7 · NOT YET IMPLEMENTED**

Prometheus, Grafana, and node_exporter.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Install node_exporter on every host in the monitored group
- Install Prometheus on the monitoring host
- Generate scrape targets from the inventory
- Alert rules: disk, memory, service down, certificate expiry
- Install Grafana with provisioned dashboards and datasources
- SNMP exporter for switches, routers, and the UPS (later)

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `monitoring_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `prometheus_version` | `"2.53.0"` | — |
| `prometheus_retention_time` | `"30d"` | — |
| `prometheus_retention_size` | `"8GB"` | cap it; server3 is not large |
| `prometheus_scrape_interval` | `"30s"` | — |
| `prometheus_scrape_targets` | `"{{ groups['monitored'] | default([]) }}"` | derived from the inventory, never hand-listed |
| `node_exporter_version` | `"1.8.2"` | — |
| `node_exporter_port` | `9100` | — |
| `grafana_admin_user` | `"admin"` | — |
| `grafana_anonymous_access` | `false` | — |

## Example play

```yaml
- name: Configure monitoring
  hosts: infra
  become: true
  roles:
    - role: monitoring
      tags: [monitoring]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `monitoring_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
