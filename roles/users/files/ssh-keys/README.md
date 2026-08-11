# SSH public keys

Drop **public** keys here — `.pub` files only — then list the filenames in
`group_vars`:

```yaml
users_admin_ssh_keys:
  - christine.pub
  - ahmed.pub
```

Ansible's file lookup resolves these relative to `roles/users/files/`, which is
why they live here rather than in the repository-root `files/` directory.

## Naming

One file per person, named after them: `christine.pub`, `ahmed.pub`. Not
`id_rsa.pub` — in six months nobody will remember whose that was, and you cannot
revoke a key you cannot identify.

## Generating one

```bash
ssh-keygen -t ed25519 -C "christine@jengasec" -f ~/.ssh/jengasec
```

Ed25519, not RSA: shorter, faster, and no key-size decision to get wrong.

Then send the **`.pub`** file. The file without `.pub` is the private key and
must never leave the machine that generated it.

## Before committing

```bash
head -c 4 christine.pub
```

It must start with `ssh-`. A private key starts with `-----BEGIN`. If you see
that, stop — you are about to commit a private key. Delete it, generate a new
pair, and treat the old one as compromised.

`.gitignore` excludes `*.pub` in this directory by default, so adding a real key
takes a deliberate `git add -f`. That is intentional: it makes committing a key
a decision rather than an accident.

## Removing someone's access

Delete their `.pub` file, remove the filename from `group_vars`, and re-run.

Deleting the file alone does **not** revoke the key — `authorized_key` only adds
unless `users_ssh_exclusive: true` is set. With it off, the key stays on the
server. Set `users_ssh_exclusive: true` once every current member's key is
committed here; from then on this directory is the single source of truth and
anything else on a server gets removed.
