# `dns`

**Phase 2 · Implemented**

Bind9, serving `jengasec.local` authoritatively and acting as the recursive
resolver for the competition LAN.

## Adding a record

Edit `dns_records` in `group_vars/dns/main.yml`. Nothing in this role changes.

```yaml
dns_records:
  - { name: "scoreboard", type: A,     value: "10.0.0.11" }
  - { name: "range",      type: CNAME, value: "server1" }

dns_reverse_records:
  - { octet: "11", name: "server1.jengasec.local." }
```

Two rules that cost people an afternoon each:

- **PTR targets must end with a dot.** Without it, `server1.jengasec.local`
  silently becomes `server1.jengasec.local.0.0.10.in-addr.arpa`.
- **The reverse `octet` is the last part only.** `10.0.0.11` is written `11` —
  the zone name already carries the network part, reversed.

## The recursion ACL is the important part

`allow-recursion { jengasec-lan; }` — the LAN and localhost, nothing else.

A recursive resolver that answers anyone is an amplification weapon: a small
spoofed query produces a large reply aimed at whoever the attacker chose, so
your server becomes the gun. It is also how a resolver ends up on public abuse
lists and gets the university's address range blocked.

**Never widen `dns_recursion_allowed_from` to `any`.**

Alongside it: zone transfers are refused (`allow-transfer { none; }`), both
globally and per-zone. An unrestricted AXFR hands over every hostname and
address on the network in a single query, and it is the first thing anyone
points at a nameserver they have just found.

## Serial numbers and idempotence

A zone serial must increase when the zone changes, or caches keep serving stale
data. The obvious implementation — generate one from today's date every run —
rewrites the file every time, so the role never reports "no change" and Bind
reloads on every play.

Instead the role renders the zone with the serial it *already has*, compares
that against the live file, and bumps only when the rest of the content
genuinely differs. That is why the second run reports zero changes, which is the
signal we use to tell a working scaffold from a broken one.

## Validation before reload

`named-checkconf -z` for the configuration, `named-checkzone` for each zone,
both before the reload handler is allowed to run. A zone file with one typo
makes Bind refuse to load the entire zone — and then nothing on the network
resolves, including the name of the server you would use to fix it.

The handler reloads rather than restarts, so the cache survives.

## DNSSEC

Validation of *upstream* answers is on (`dnssec-validation auto`).

Signing our own zone is deliberately not implemented. `jengasec.local` is not
delegated from the public root, so there is no chain of trust to validate
against — every client would need the key installed by hand. It buys nothing
here. Worth revisiting if the club moves to a real delegated domain.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `dns_zone` | `jengasec.local` | |
| `dns_records` | `[]` | Set in `group_vars/dns` |
| `dns_reverse_records` | `[]` | |
| `dns_recursion_allowed_from` | localhost + LAN | **Do not widen** |
| `dns_forwarders` | `1.1.1.1`, `8.8.8.8` | Point at campus resolvers |
| `dns_forward_policy` | `first` | `only` if policy requires it |
| `dns_allow_transfer` | `[]` | Add a secondary only if you run one |
| `dns_query_logging` | `false` | One line per query — a lot of disk |
| `dns_rate_limit_enabled` | `true` | 15 identical responses/sec per subnet |
| `dns_hide_version` | `true` | |

## Tags

`dns`, `packages`, `config`, `zones`, `validate`, `service`, `verify`,
`logging`

## Verifying

```bash
sudo named-checkconf -z
dig @10.0.0.12 platform.jengasec.local
dig @10.0.0.12 -x 10.0.0.11
dig @10.0.0.12 debian.org
dig @10.0.0.12 jengasec.local AXFR          # must be REFUSED
```

The last one is the test that matters. If it returns records instead of
`Transfer failed`, the transfer ACL is not doing its job.

From a machine **outside** the LAN, this must time out or be refused:

```bash
dig @<server2-public-address> google.com
```

If it answers, you have an open resolver. Fix it before anything else.
