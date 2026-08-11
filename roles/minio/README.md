# `minio`

**Phase 8 · NOT YET IMPLEMENTED**

S3-compatible object storage for submissions at scale.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Install the MinIO server and client
- Create buckets, policies, and service users
- TLS using the internal CA
- Bucket versioning and lifecycle rules
- Replication to the backup host

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `minio_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `minio_version` | `"latest"` | — |
| `minio_data_dir` | `"/srv/minio"` | — |
| `minio_api_port` | `9000` | — |
| `minio_console_port` | `9001` | — |
| `minio_buckets` | `[]` | list of dicts: name, policy, versioning |
| `minio_root_user` | `"jengasec"` | — |
| `minio_root_password` | `"{{ vault_minio_root_password | default(omit) }}"` | add the key to vault.yml before enabling |

## Example play

```yaml
- name: Configure minio
  hosts: infra
  become: true
  roles:
    - role: minio
      tags: [minio]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `minio_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
