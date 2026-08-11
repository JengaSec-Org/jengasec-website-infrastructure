# Decisions

Why the infrastructure looks like this. Each entry records the reasoning and,
where relevant, what would change our mind — a decision without a reversal
condition is a preference wearing a costume.

---

## No Docker, no Kubernetes

**Native systemd deployment: nginx + gunicorn + PostgreSQL + Redis.**

The servers have 8 GB and 4 GB of RAM. A container runtime costs memory and,
more importantly, debugging effort — during a competition, "why is the container
not starting" is a worse problem to have at 2am than "why is the service not
starting", because there is an extra layer between you and the answer.

systemd already provides what people usually reach for containers to get:
supervision, restart policy with backoff, dependency ordering, resource limits,
journal logging, and a sandbox. Kubernetes on three servers of this size is
overhead in search of a problem.

The platform README lists "Docker + Gunicorn + Nginx (planned)". This repository
takes the other path deliberately. Note that the competition *itself* involves
Docker — blue teams ship systems as Docker images, red teams attack dockerized
replicas — but that is workload, not infrastructure, and it belongs on the cyber
range rather than under the platform.

**Reconsider if:** the club moves to cloud hosting, needs to run more than one
application per host, or grows past what one person can deploy by hand.

---

## Python 3.11, not 3.12

Debian 12 ships Python 3.11. The platform README asks for 3.12+, but that is a
preference rather than a requirement: Django 5.0 and 5.1 both support 3.11, and
every package in `requirements.txt` — psycopg2-binary, PyMuPDF, pdfplumber,
reportlab, pandas, gunicorn, whitenoise — has a 3.11 wheel.

Building Python from source means owning its security updates by hand, forever.
Debian will not patch it for you. That is a poor trade for a version number.

The `python` role has the source-build tasks written and disabled behind
`python_build_from_source`, using `make altinstall` so it can never shadow the
system interpreter — apt is written in Python, and recovering a server whose
system Python was replaced is genuinely unpleasant.

**Reconsider if:** a dependency genuinely requires 3.12. Then it is one variable.

---

## UFW, not nftables

Both were on the table. UFW won on two grounds:

1. **Fewer ways to lock yourself out.** The firewall role already carries three
   layers of protection against that; nftables would need more, and the failure
   mode is the same either way — a server nobody can reach.
2. **The Ansible module is mature.** `community.general.ufw` handles rule
   idempotence correctly, which matters for the "second run reports zero
   changes" rule this repository is built around.

The usual argument for nftables — that students see the real ruleset rather than
a wrapper — is answered by keeping the ruleset as **data** in `group_vars`. The
rules are readable in one place, and `iptables -L -n -v` still shows what UFW
generated for anyone who wants to look underneath.

**Reconsider if:** you need rules UFW cannot express — connection tracking
tricks, NAT for the cyber range, or per-interface policies.

---

## The ruleset is data, not code

Firewall rules, DNS records, DHCP reservations, and service accounts are all
lists of dicts in `group_vars`, looped over in tasks and templates.

Adding a DNS record or opening a port is then a data edit that a club member can
make and review without reading any Ansible. It also means a code review of a
change shows the actual intent — `port: 5432 from: 10.0.0.11` — rather than a
diff in a task file.

---

## Every managed file is a Jinja2 template

Not `copy`, not `lineinfile`. If Ansible owns a file, it renders the whole file.

`lineinfile` produces configurations that are the sum of many partial edits, and
after a few months nobody can say what the file should look like — only what was
last changed. A template is the single answer to "what is in this file and why".

**One deliberate exception:** `/etc/login.defs` in the `security` role. It
carries many distribution defaults that are correct and that we have no reason
to own, so seven specific keys are set with `lineinfile` and the rest is left to
Debian.

---

## `networking_configure` defaults to false

The role that reconfigures the interface you are connected over is off until you
turn it on.

If the servers already have working static addresses from the Debian installer,
leaving it off permanently is a reasonable choice. Ansible does not have to own
everything to be useful, and the interface configuration is the one place where
being wrong costs a trip to the server room.

---

## `dhcp_configure` defaults to false

Exactly one DHCP server may be authoritative on a broadcast domain. If the
campus network already runs one, deploying ours hands out conflicting leases to
every device on the segment — a network-wide outage caused by the club, which is
the kind of thing that ends a club's network access.

It is only appropriate on an isolated competition segment.

---

## Internal CA, not Let's Encrypt

`jengasec.local` is not delegated from the public root — `.local` is reserved
for mDNS. **No public CA will ever issue a certificate for it.** This is
structural, not a configuration choice.

So the default is a private CA whose key lives on one host and never moves. The
Let's Encrypt provider is implemented and waiting for a real domain.

Club laptops will show a certificate warning until the CA is installed on them.
That is the cost, and it is the honest one — the alternative is turning off
verification, which teaches exactly the wrong lesson at a cybersecurity club.

---

## Two audit trade-offs that go against the benchmark

Both are places where the strict CIS answer would take the competition platform
down mid-event:

| Setting | CIS | Ours | Reasoning |
|---|---|---|---|
| auditd buffer overflow (`-f`) | `2`, kernel panic | `1`, printk | A burst of audit events should not halt the server. The kernel log still records that events were lost. |
| `disk_full_action` | `halt` | `rotate` | A full disk becomes a total outage. We lose the oldest history instead. |

If this were a system of record rather than a competition platform, both would
go the other way. They are documented at the point where the choice is made, in
`roles/audit/defaults/main.yml`, rather than left as silent deviations.

---

## Compilers are not removed

CIS-style hardening recommends restricting compilers. The `common` role installs
`build-essential` anyway, because pip needs it to build psycopg2 and PyMuPDF
from source.

Removing compilers would break deployment. This is an honest, documented trade
rather than a silent gap.

**Reconsider if:** the club builds wheels on a separate machine and ships those
instead. Then `security_restrict_compilers` becomes worth turning on.

---

## IPv6 is disabled

Not because IPv6 is bad, but because a half-configured IPv6 stack is worse than
none. Every firewall rule in this repository is v4-only, so an unmanaged v6
address hands out reachability nobody intended and nobody thought to filter —
while everyone believes the host is protected.

`networking_ipv6_enabled` and `firewall_ipv6` must be turned on **together**.

---

## Roles are grouped by function, not by machine

The inventory has `web`, `database`, `dns`, `backup`, `monitoring` — not
`server1`, `server2`, `server3`.

Moving PostgreSQL to a different box is then an inventory edit rather than a
change to any role or playbook, and the same layout survives the club adding a
fourth server.

---

## Stubs fail loudly

The 14 unimplemented roles raise an error rather than doing nothing quietly.

A green Ansible run that changed nothing is the most expensive kind of bug in
infrastructure code: you believe a machine is configured when it is not, and you
find out during the event. Every stub says exactly what did not happen and where
to read about it.
