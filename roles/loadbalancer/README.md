# `loadbalancer`

**Phase 6 · NOT YET IMPLEMENTED**

HAProxy or nginx load balancing across application hosts.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Reverse proxy to multiple backends
- Round-robin and least-connections algorithms
- Active health checks with backend ejection
- Sticky sessions for the judging workflow
- TLS offloading
- Stats endpoint, restricted to the LAN

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `loadbalancer_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `loadbalancer_engine` | `haproxy` | haproxy | nginx |
| `loadbalancer_algorithm` | `leastconn` | roundrobin | leastconn | source |
| `loadbalancer_backends` | `[]` | list of dicts: name, address, port, weight |
| `loadbalancer_health_check_path` | `"/healthz/"` | the app must expose this |
| `loadbalancer_health_check_interval` | `"5s"` | — |
| `loadbalancer_sticky_sessions` | `true` | judges lose work if their session moves |
| `loadbalancer_stats_enabled` | `true` | — |

## Example play

```yaml
- name: Configure loadbalancer
  hosts: infra
  become: true
  roles:
    - role: loadbalancer
      tags: [loadbalancer]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `loadbalancer_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
