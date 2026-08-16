# `storage`

**Phase 8 · Implemented, disabled by default**

Mount points, fstab entries, quotas, and disk guards.

## A deliberately narrow role

This role owns **mount points and nothing else**.

The application directories already have two owners: `django` creates them and
`filesystem-security` enforces their modes. A third role chowning the same paths
is exactly the collision the house rules forbid — the result would depend on
which role ran last.

`storage_media_dir` and friends are in the defaults so a mount can be *pointed
at* them. The role does not chown them.

| Concern | Owner |
|---|---|
| Mounts, fstab, quotas | **`storage`** |
| Creating app directories | `django` |
| Their ownership and modes | `filesystem-security` |
| Journal size | `os` |
| Log rotation | `logging` |

## Off by default, and that is honest

On three servers with local disks there is nothing to mount. An empty
`storage_mounts` makes the role a no-op anyway — being explicit about that is
better than pretending it does something.

Disk usage is still reported on every run regardless.

## Two guards worth having

**It refuses to mount over a non-empty directory.** The mount succeeds, the
existing files vanish from view, and they stay on the underlying filesystem
consuming space — reappearing only on unmount, which nobody thinks to try
because the symptom is "the uploads are gone".

**It warns about `/dev/sdX` in fstab.** Device names are not stable: add a disk
and yesterday's `/dev/sdb` becomes `/dev/sdc`. At boot either the wrong
filesystem mounts over the media directory, or nothing mounts and the
application quietly writes to the root disk instead. Use `UUID=` — find it with
`blkid`.

## Mount options

```
defaults,noatime,nodev,nosuid,noexec
```

`noexec` on the media volume is the one that matters here: it holds files
uploaded by competitors, and nothing there should ever be executable.

`noatime` avoids a metadata write on every read, which is worth having on a
directory that judges browse repeatedly.

## Quotas apply per filesystem

`storage_quota_enabled` is off, and the role **refuses to enable it** unless the
target is its own mount point.

Quotas are a filesystem feature, not a directory one. Turning it on without a
dedicated media volume would limit the whole root filesystem — emphatically not
what anyone means by "cap the uploads directory".

## Adding a volume

```yaml
storage_enabled: true
storage_mounts:
  - src: "UUID=1a2b3c4d-5e6f-7890-abcd-ef1234567890"
    path: "/opt/jengasec/app/media"
    fstype: ext4
    opts: "defaults,noatime,nodev,nosuid,noexec"
```

Run the `django` and `filesystem-security` roles afterwards — a fresh filesystem
mounts empty and owned by root, so ownership has to be re-applied.

## Variables

| Variable | Default |
|---|---|
| `storage_enabled` | `false` |
| `storage_mounts` | `[]` |
| `storage_default_mount_opts` | `defaults,noatime,nodev,nosuid,noexec` |
| `storage_quota_enabled` | `false` |
| `storage_check_paths` | `/`, `/var`, media |
| `storage_warn_percent` | `85` (from `os_disk_usage_warn_percent`) |
| `storage_refuse_nonempty_mountpoint` | `true` |

## Tags

`storage`, `packages`, `mounts`, `quota`, `verify`

## Verifying

```bash
df -hT
findmnt --verify
cat /etc/fstab
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
```

`findmnt --verify` is the useful one — it checks fstab for entries that would
fail at boot, which is otherwise something you discover during a reboot you
were not expecting to be eventful.

If quotas are on:

```bash
repquota -a
```
