# `vars/`

Playbook-level variable files, loaded explicitly with `vars_files`.

**Empty on purpose, and it should probably stay that way.**

Variables in this repository live in one of three places, and each has a clear
reason:

| Location | For |
|---|---|
| `roles/<role>/defaults/main.yml` | A safe default so the role runs standalone. **Overridable.** |
| `inventories/<env>/group_vars/` | Site and per-function choices |
| `inventories/<env>/host_vars/` | Machine-specific facts |

Full precedence table in [docs/variables.md](../docs/variables.md).

## Why this directory is a trap

`vars_files` loads at a precedence **above** `group_vars` and `host_vars`. A
value here silently overrides the inventory — so someone reads `group_vars`,
sees the value they expect, and cannot work out why the host behaves
differently. The answer is in a file they had no reason to open.

Two legitimate uses:

- **Constants that are not configuration** — a lookup table, a mapping of
  distribution names to package names. Things nobody would ever want to override
  per host.
- **A role's internal `vars/main.yml`**, which is the correct place for values a
  role uses but that must *not* be overridden. That lives in the role, not here.

If you are about to add a file to this directory, check whether it belongs in
`group_vars` instead. It usually does.
