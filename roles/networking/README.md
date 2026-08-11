# `networking`

**Phase 2 · Implemented**

Static addressing, resolver configuration, and static routes, using Debian 12's
default ifupdown stack.

> **This role can drop your SSH session.** It reconfigures the interface you are
> almost certainly connected over. That is why it is **not** in
> `bootstrap.yml` — it lives in `playbooks/networking.yml` and is run
> deliberately, with console access available.

## It is off by default

`networking_configure: false`. Turning it on is a conscious decision, made once
you know the real interface name and have a way back into the box.

If the servers already have working static addresses from the Debian installer,
it is entirely reasonable to leave this off permanently. Ansible does not have
to own everything to be useful, and the interface configuration is the one place
where being wrong is expensive.

With it off, the role still manages `/etc/hosts` entries — those are safe and
useful on their own.

## Check the interface name first

```bash
ip -brief link show
```

Debian 12 uses predictable names: `ens18`, `enp0s3`, `eno1`. It is **rarely**
`eth0`. Applying a config to an interface that does not exist takes the machine
off the network with no error at apply time — so the role asserts the interface
is present in `ansible_interfaces` before it writes anything.

## Safety measures

| Measure | What it prevents |
|---|---|
| `networking_configure` defaults false | Accidental application during a routine run |
| Asserts address, gateway, DNS are all set | A partial config that takes the host offline |
| Asserts the interface exists | The `eth0` vs `ens18` mistake |
| Writes to `interfaces.d/`, not the main file | Losing the installer's original config |
| Ensures the main file `source`s that directory | A drop-in written and silently ignored |
| `ifdown && ifup` on one interface | `systemctl restart networking` takes down *every* interface |
| `async` + `wait_for_connection` | Ansible hanging on a socket that no longer exists |
| Pings the gateway afterwards | A broken config that looks like a successful run |

## `/etc/resolv.conf` is written directly

Neither `resolvconf` nor `systemd-resolved` is installed by default on Debian
12, so the `dns-nameservers` lines in `interfaces.d` would do nothing on their
own. The role writes the resolver file itself.

If you later install systemd-resolved, that file becomes a symlink it manages —
set `networking_manage_resolv_conf: false` and revisit this role.

## IPv6

Disabled by default. Not because IPv6 is bad, but because a half-configured IPv6
stack is worse than none: the firewall rules in this repository are v4-only, so
an unmanaged v6 address hands out reachability you did not intend and did not
think to filter. Enable it only when you are ready to firewall it too.

## Variables

Set per host in `host_vars/serverN.yml`.

| Variable | Default | Notes |
|---|---|---|
| `networking_configure` | `false` | The master switch |
| `networking_interface` | `eth0` | **Check this** |
| `networking_method` | `static` | `static` or `dhcp` |
| `networking_address` / `_netmask` / `_gateway` | `""` | Required for static |
| `networking_dns_servers` | `[]` | Required |
| `networking_ipv6_enabled` | `false` | |
| `networking_hosts_entries` | `[]` | Static entries for the other servers |
| `networking_verify_after_change` | `true` | |

## Running it

```bash
ansible-playbook -i inventories/production playbooks/networking.yml \
    --limit server1 --tags networking
```

Do **server1 last**, not first — it is the host you most need reachable, and by
then you will have made the same change twice already.

## Tags

`networking`, `interface`, `dns`, `hosts`, `ipv6`, `verify`

## Verifying

```bash
ip -brief addr show
ip route show
cat /etc/resolv.conf
ping -c2 10.0.0.1
getent hosts server2.jengasec.local
```

## If you lose the host

Console access, then:

```bash
sudo ifdown eth0 --force
sudo mv /etc/network/interfaces.d/50-jengasec.cfg /root/
sudo ifup eth0
```

The role writes with `backup: true`, so the previous version is kept alongside
with a timestamp.
