# `minio`

**Phase 8 · Implemented, disabled by default**

S3-compatible object storage.

## You almost certainly do not need this

The `django` role stores uploads on local disk and nginx serves them from there.
That works, it is fast, and the `backup` role already covers it.

Object storage earns its place when **submissions outgrow one disk**, or when
**more than one application host needs the same files**. Three servers and one
web host is neither.

Implemented so that day is a config change rather than a build. Off until then.

## The update problem

MinIO has no APT repository. This is a **pinned `.deb` with a checksum**, which
means **you own its updates by hand** — nothing will tell you when a security
release lands.

That is a real argument for leaving it off, and it is the opposite trade from
Grafana, where the third-party APT source was worth it precisely to get
automatic updates.

`minio_deb_checksum` ships as a placeholder and the role warns while it is still
there. Get the real one:

```bash
curl -sL https://dl.min.io/server/minio/release/linux-amd64/archive/minio_<version>_amd64.deb.sha256sum
```

## Guards

| Guard | Prevents |
|---|---|
| Root password ≥ 16 chars | Credentials that reach every submission being guessable |
| Refuses `0.0.0.0` | The console — a full admin interface — on every interface |
| Placeholder checksum warning | A bare hash mismatch with no explanation |

The console deserves the emphasis: it creates buckets, browses objects, and
mints access keys. On a competition network that is not something to expose.

## Buckets

```yaml
minio_buckets:
  - name: jengasec-submissions
    policy: none          # private — credentials required
    versioning: true
```

**`policy: none` means private.** A submissions bucket set to `public` would put
every uploaded document on the open internet with a guessable URL. There is no
scenario in this competition where that is correct.

**Versioning is on for submissions** so a replaced upload does not destroy the
first — which matters when a team re-submits before a deadline and a judge needs
to see what was there originally.

**Versioning needs expiry.** Without it the bucket grows forever, and on a spare
box that is how the disk fills silently, months later.
`minio_noncurrent_version_expiry_days` handles it.

## Use per-application keys, not root

The root credentials in `/etc/default/minio` reach everything. Do not hand them
to Django:

```bash
mc admin user add jengasec django-app <a-generated-secret>
mc admin policy attach jengasec readwrite --user django-app
```

A leaked application key can then be revoked without rotating everything.

## Not a resilient object store

A single `MINIO_VOLUMES` path is one disk with no redundancy — MinIO's erasure
coding needs four or more. That is fine here because the `backup` role covers
this host, but it should not be mistaken for durability.

## Variables

| Variable | Default |
|---|---|
| `minio_enabled` | `false` |
| `minio_version` | pinned release |
| `minio_deb_checksum` | placeholder — **replace** |
| `minio_bind` | private address |
| `minio_api_port` / `_console_port` | `9000` / `9001` |
| `minio_root_password` | `{{ vault_minio_root_password }}` |
| `minio_buckets` | submissions, backups — both private |
| `minio_tls_enabled` | `true` |
| `minio_noncurrent_version_expiry_days` | `90` |

## Tags

`minio`, `packages`, `directories`, `tls`, `config`, `service`, `buckets`,
`verify`

## Verifying

```bash
systemctl status minio
curl -k https://10.0.0.13:9000/minio/health/live
mc --insecure ls jengasec
mc --insecure admin info jengasec
```

Confirm the submissions bucket is genuinely private — this must **fail**:

```bash
curl -k https://10.0.0.13:9000/jengasec-submissions/
```

If it lists objects, the policy is wrong and every uploaded document is
readable by anyone who can reach the port.

## Firewall

Nothing opens 9000 or 9001. Add rules to `group_vars/backup` if the application
host needs to reach it — and only from that host, the same way PostgreSQL is
restricted.
