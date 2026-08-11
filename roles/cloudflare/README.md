# `cloudflare`

**Phase 9 · NOT YET IMPLEMENTED**

Public access via Cloudflare DNS, Tunnel, and WAF.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- cloudflared Tunnel, so no inbound port needs opening
- DNS record management through the API
- Firewall and rate-limiting rules
- Origin certificates
- Decide Tunnel vs public DNS according to campus network policy

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `cloudflare_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `cloudflare_mode` | `tunnel` | tunnel | dns — tunnel needs no inbound ports |
| `cloudflare_api_token` | `"{{ vault_cloudflare_api_token }}"` | — |
| `cloudflare_zone_id` | `"{{ vault_cloudflare_zone_id }}"` | — |
| `cloudflare_tunnel_name` | `"jengasec"` | — |
| `cloudflare_dns_records` | `[]` | — |
| `cloudflare_proxied` | `true` | orange cloud — hides the origin address |

## Example play

```yaml
- name: Configure cloudflare
  hosts: infra
  become: true
  roles:
    - role: cloudflare
      tags: [cloudflare]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `cloudflare_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
