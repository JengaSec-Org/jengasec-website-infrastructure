# `dhcp`

**Phase 2 · Implemented, disabled by default**

isc-dhcp-server for the competition LAN.

> ## Read this before enabling
>
> **Exactly one DHCP server may be authoritative on a broadcast domain.**
>
> If the campus network already runs one, deploying this hands out conflicting
> leases to every device on the segment — not just yours. That is a network-wide
> outage caused by your lab, and it is the kind of thing that ends a club's
> access to the network.
>
> Confirm with the network administrator first. This is why
> `dhcp_configure: false` is the default.

## When you actually want this

A DHCP server of your own makes sense when the competition runs on an **isolated
segment** — its own VLAN or a physically separate switch — where you control
addressing end to end. On a shared campus LAN, use the existing server and add
reservations there instead.

## Enabling it

```yaml
# group_vars/dhcp/main.yml
dhcp_configure: true
dhcp_subnets:
  - network: "10.0.0.0"
    netmask: "255.255.255.0"
    range_start: "10.0.0.100"
    range_end: "10.0.0.200"
    gateway: "10.0.0.1"
    broadcast: "10.0.0.255"
```

The dynamic range starts at `.100` on purpose, leaving `.1`–`.99` for
infrastructure and reservations so a server never collides with a laptop.

## Reservations

```yaml
dhcp_reservations:
  - hostname: red-team-workstation-01
    mac: "aa:bb:cc:dd:ee:01"
    ip: "10.0.0.50"
```

The role **asserts reservations fall outside the dynamic range**. A reservation
inside the pool can be leased to another client before the reserved host asks
for it, and the two then conflict intermittently — which presents as "the
network is flaky" rather than as a configuration error, so it is worth catching
at apply time.

## Safety measures

| Measure | What it prevents |
|---|---|
| `dhcp_configure` defaults false | Accidentally becoming a second DHCP server |
| Asserts subnets, interfaces, nameservers are set | Leases that leave clients unable to resolve anything |
| Asserts reservations sit outside the pool | Intermittent address conflicts |
| `validate: dhcpd -t -cf %s` | A config error stopping the daemon |
| Explicit `INTERFACESv4` | Answering on a network you do not own |

## Dynamic DNS is off

`ddns-update-style none`. Letting DHCP write into Bind means anything that can
request a lease can create a DNS record — including one that shadows an existing
service name. On a network full of people actively looking for a way in, that is
not a feature.

## PXE

Off. The template carries the `next-server` / `filename` stanzas commented out,
ready for when a TFTP server exists for imaging competition machines.

## Variables

| Variable | Default |
|---|---|
| `dhcp_configure` | `false` |
| `dhcp_interfaces` | `[{{ networking_interface }}]` |
| `dhcp_subnets` | `[]` |
| `dhcp_reservations` | `[]` |
| `dhcp_default_lease_time` | `3600` |
| `dhcp_authoritative` | `true` |
| `dhcp_pxe_enabled` | `false` |

## Tags

`dhcp`, `packages`, `config`, `validate`, `service`, `verify`

## Verifying

```bash
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
sudo systemctl status isc-dhcp-server
sudo journalctl -u isc-dhcp-server -f
cat /var/lib/dhcp/dhcpd.leases
```

From a client on the segment:

```bash
sudo dhclient -v eth0
```

Watch the server's journal while that runs — you should see DISCOVER, OFFER,
REQUEST, ACK. If you see an OFFER from an address you do not recognise, there is
another DHCP server on the network and you should stop yours immediately.
