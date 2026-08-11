# `storage`

**Phase 8 · NOT YET IMPLEMENTED**

Filesystem layout, mount points, and permissions for application data.

## Status

This role is a stub. Running it raises a failure rather than silently doing
nothing — see `tasks/main.yml` for why.

## Planned responsibilities

- Create and own the media, static, and log directories
- Mount additional volumes from storage_mounts
- Enforce quotas where a directory could fill the disk
- Set the retention policy for uploaded submissions

## Variables

Defined in `defaults/main.yml`; override in `group_vars/`, never by editing the
role.

| Variable | Default | Notes |
|---|---|---|
| `storage_enabled` | `false` | Guard. Set true only once the tasks exist. |
| `storage_mounts` | `[]` | list of dicts: src, path, fstype, opts |
| `storage_media_dir` | `"{{ app_media_dir }}"` | — |
| `storage_static_dir` | `"{{ app_static_dir }}"` | — |
| `storage_log_dir` | `"{{ app_log_dir }}"` | — |
| `storage_dir_mode` | `"0750"` | group-readable, never world-readable |
| `storage_quota_enabled` | `false` | — |

## Example play

```yaml
- name: Configure storage
  hosts: infra
  become: true
  roles:
    - role: storage
      tags: [storage]
```

## Implementing this role

1. Fill in `defaults/main.yml` — every value the role needs, none of them literal in tasks.
2. Write the templates in `templates/` as `.j2`, each starting with the managed banner.
3. Write `tasks/main.yml`, referencing only variables.
4. Add handlers for anything that needs a restart or reload.
5. Delete the `fail` task and flip `storage_enabled` to `true`.
6. Update the status table in [docs/roles.md](../../docs/roles.md).
7. `make lint && make syntax`, then run twice against staging — the second run
   must report zero changes.
