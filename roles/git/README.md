# `git`

**Phase 1 · Implemented**

Git, system-wide configuration, and host key trust.

**This role does not clone the application.** That belongs to the `django` role,
which owns the application directory and knows what has to happen after a
checkout changes (migrations, collectstatic, a gunicorn reload). This role only
makes cloning possible and safe.

## What it sets, and why

| Setting | Reason |
|---|---|
| `core.autocrlf = input`, `core.eol = lf` | This repo is authored on Windows and deployed on Debian. CRLF reaching a shell script produces `bad interpreter: /bin/bash^M`. |
| `transfer.fsckObjects` and friends | Verify object integrity on fetch — catches a corrupted or tampered transfer. |
| `core.protectHFS`, `core.protectNTFS` | Refuse filenames differing only by case or Unicode normalisation, a known way to sneak a second file past review. |
| `user.useConfigOnly` | Never guess an identity. A commit authored by `root@server1` tells you nothing. |
| `safe.directory` | Git refuses repositories owned by another user (CVE-2022-24765). The app checkout is listed explicitly rather than disabling the protection globally with `*`. |

## Host keys

`git_manage_known_hosts` is off, because the platform repository is public and
cloned over HTTPS.

Turn it on only for SSH clones, and fetch the key yourself:

```bash
ssh-keyscan -t ed25519 github.com
```

Do not paste a key from somewhere you have not verified — pre-seeding
`known_hosts` is worth doing precisely because it prevents a silent
machine-in-the-middle, and a wrong key defeats the point. The role warns rather
than proceeding if the key is left empty.

## Deploy keys

Off by default. Only needed for a private repository.

If you enable it, use a **repository-scoped, read-only deploy key**. A personal
account key on a server gives anyone who compromises that server your full
access to every repository you can reach.

## Variables

| Variable | Default |
|---|---|
| `git_packages` | `git`, `git-lfs` |
| `git_manage_system_config` | `true` |
| `git_config` | see defaults |
| `git_safe_directories` | `[{{ app_source_dir }}]` |
| `git_manage_known_hosts` | `false` |
| `git_deploy_key_enabled` | `false` |

## Tags

`git`, `packages`, `config`, `known-hosts`, `deploy-key`

## Verifying

```bash
git --version
git config --system --list
git config --system --get core.autocrlf
```
