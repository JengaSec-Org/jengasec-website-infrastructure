# `files/`

Static files shared across roles — content that is copied verbatim rather than
rendered from a template.

**Most files belong to a role, not here.** Ansible's `copy` and `file` lookups
resolve `roles/<role>/files/` automatically, which is why SSH public keys live
in [`roles/users/files/ssh-keys/`](../roles/users/files/ssh-keys/README.md)
rather than in this directory.

Use this only for something genuinely shared by several roles, and reference it
with an explicit path.

## Rule of thumb

| Content | Where |
|---|---|
| Anything with a `{{ variable }}` in it | `roles/<role>/templates/*.j2` |
| Static, used by one role | `roles/<role>/files/` |
| Static, used by several roles | here |

If you are about to put a config file in a `files/` directory, check first
whether it should be a template. Almost always it should — a static config that
hardcodes a hostname or a path is the thing this repository is built to avoid.
