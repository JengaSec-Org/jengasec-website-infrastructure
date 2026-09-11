# `tailscale`

**Phase 9 · Implemented · off by default**

Joins a host to a Tailscale tailnet and, when routes are advertised, makes it a
subnet router for the lab segment. This is how the *organisers* reach the
servers from off campus — SSH, Grafana, the Proxmox console — with no inbound
port and no request to anyone's firewall team.

## Not the public route

`cloudflare` and `tailscale` both solve "the campus NAT blocks everything
inbound", both by dialling out and holding the connection open. They answer
different questions:

| | `cloudflare` | `tailscale` |
|---|---|---|
| Who | the public — competitors, judges' browsers | organisers with the Tailscale app |
| What | one HTTPS origin, `/admin/` behind Access | every port on the host, and the LAN behind it |
| Trust | Cloudflare's edge terminates TLS | WireGuard, keyed per device; control plane only brokers keys |
| Identity | email via Access | device + user, decided by tailnet ACLs |

A tailnet is a private network, not a website. Nothing on it is reachable from
the internet, and everything on it is reachable by every device the ACLs
permit. That is exactly what remote administration wants and exactly what
public traffic must never have.

## Why a subnet router on the VM, not Tailscale on Proxmox

Installing Tailscale on the hypervisor would be the obvious way to reach the
Proxmox UI from home. The runbook's rule is that nothing runs on the hypervisor
and it is in no inventory, so instead the `jengasec` VM advertises
`192.168.40.0/24`. A laptop on the tailnet then reaches the VM, the Proxmox UI
on `.7:8006`, the iDRAC, and any future VM — through one enrolled host, with
nothing installed on the rest.

Three things make that work, and the role does two of them:

1. **IP forwarding.** `/etc/sysctl.d/99-tailscale.conf` sorts after the os
   role's `60-jengasec.conf` (`ip_forward = 0`) and overrides it — only on a
   host that advertises routes, and the file is removed when the routes are.
2. **A UFW route rule** `tailscale0 → ens18`. The firewall role's routed policy
   is deny; this is the one exception.
3. **Route approval** in the admin console. Ansible cannot do this, on purpose:
   a route makes an entire LAN reachable and Tailscale wants a human to say so.
   The role's report says whether it is still pending.

Forwarded packets are source-NATed to the VM's LAN address (`--snat-subnet-routes`,
the default), so the Proxmox host sees a connection from `192.168.40.11` and
needs no route back to `100.x`. Turning SNAT off would mean a static route on
every device you want to reach.

## Why interface rules instead of the firewall role's list

The firewall role's ruleset is keyed by port and source CIDR. Tailscale wants
"allow everything arriving on `tailscale0`": WireGuard has already
authenticated the peer as a tailnet member, and the tailnet ACLs decide who may
reach which port. Copying that policy into a UFW port list would be a second,
weaker version of it that drifts.

So the role applies two interface rules directly with `community.general.ufw`.
It skips them with a warning when UFW is not installed yet — nothing is blocked
either, because there is no firewall — and `firewall_reset_before_apply: true`
would remove them, so run `make tailscale` again after a reset.

## Why `accept-dns` is off

MagicDNS rewrites `/etc/resolv.conf`. This host runs Bind9 and the networking
role owns the resolver; letting Tailscale overwrite it would break both, and
the failure would look like "DNS stopped working after the last Ansible run".
Laptops want MagicDNS. Servers do not. Other tailnet devices still resolve
*this* host by name — that is done on their side.

## Why Tailscale SSH is off

`--ssh` has tailscaled answer SSH on the tailnet with the tailnet identity as
authentication. The `ssh` role already hardens sshd, it listens on `0.0.0.0`,
and the admin keys it installs work over `tailscale0` exactly as on the LAN.
One SSH configuration to reason about and audit, not two.

## Idempotence

First run: `tailscale up --reset` with the auth key and the full flag set — the
flags on that line are the whole configuration, not a delta on whatever was
set by hand. Every later run reads `tailscale debug prefs`, compares routes,
DNS, SSH, SNAT and hostname with the inventory, and calls `tailscale set` only
on drift. A second `make tailscale` reports zero changed tasks.

The node key in `/var/lib/tailscale` is deliberately outside the backup set: a
restored VM should re-enrol with a fresh identity, not resurrect an old one.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `tailscale_enabled` | `false` | v1 turns it on in `host_vars/jengasec.yml` |
| `tailscale_auth_key` | `vault_tailscale_auth_key` | The role refuses to run without it |
| `tailscale_hostname` | `inventory_hostname` | Name on the tailnet |
| `tailscale_advertise_tags` | `[tag:jengasec-server]` | The key must be allowed to apply them |
| `tailscale_advertise_routes` | `[jengasec_network_cidr]` | Empty list = plain node, no forwarding |
| `tailscale_lan_interface` | `networking_interface` | Where forwarded traffic leaves |
| `tailscale_snat_subnet_routes` | `true` | Leave on unless every LAN device has a route to `100.x` |
| `tailscale_accept_dns` | `false` | Never on a host that runs Bind9 |
| `tailscale_accept_routes` | `false` | Servers do not need routes to laptops |
| `tailscale_ssh` | `false` | sshd already covers it |
| `tailscale_manage_firewall` | `true` | Interface rules on UFW, when UFW exists |

## Verification

```bash
sudo tailscale status                 # node + peers; a warning if the route is unapproved
tailscale ip -4                       # its 100.x address
sysctl net.ipv4.ip_forward            # 1 when routes are advertised
sudo ufw status verbose | grep tailscale0
```

Then from a phone or laptop on **mobile data** with the Tailscale app signed in:
`ssh jengasec@jengasec` and `https://192.168.40.7:8006`.

## If it breaks

| Symptom | Look at |
|---|---|
| Node never reaches `Running` | `journalctl -u tailscaled -n 50` — expired/used auth key, or the key may not apply `tag:jengasec-server` |
| Host reachable, LAN behind it is not | route not approved in the admin console; or `sysctl net.ipv4.ip_forward` is 0; or the UFW route rule is missing |
| Slow but working | `tailscale netcheck` — direct UDP is blocked and it is using a DERP relay. Still encrypted end to end |
| Name does not resolve on the laptop | MagicDNS is a *client-side* setting; use the `100.x` address |
