# `certificates`

**Phase 2 · Implemented (internal CA and Let's Encrypt)**

TLS certificates for the JengaSec servers.

## Three providers

Selected with `certificates_provider`:

| Provider | Status | Use when |
|---|---|---|
| `internal_ca` | **Implemented — the default** | `jengasec.local`, or any name that is not publicly resolvable |
| `letsencrypt` | Implemented | You have a real public domain and inbound port 80 |
| `cloudflare_origin` | Stub (Phase 9) | Behind a Cloudflare proxy or Tunnel |

The default is `internal_ca` for a structural reason: `.local` is reserved for
mDNS and is not delegated from the public root, so **no public CA will ever
issue a certificate for `jengasec.local`**. Let's Encrypt is not an option until
the club has a real domain.

## How the internal CA works

The CA lives on **one** host — the first in the `infra` group — and its private
key never leaves that machine. Signing happens there via `delegate_to`; only
CSRs and signed certificates travel.

```
server1 (CA host)                other hosts
  jengasec-ca.key   <- never leaves this machine
  jengasec-ca.crt   ------------->  installed into the system trust store
                    <-------------  CSR
  sign
                    ------------->  signed certificate
```

The CA key is encrypted with `vault_ca_passphrase`, and the role **refuses to
run without it**. An unprotected CA key means anyone who gets a shell on that
host can issue a valid certificate for any name in your network — including the
platform's. For an event where people are actively looking for a way in, that is
the whole game.

`pathlen:0` on the CA means it can sign server certificates but not further
CAs, so a compromised certificate cannot be used to build a signing hierarchy.

## Trust distribution

`certificates_install_ca_trust: true` puts the CA certificate into the system
trust store on every host. After that, `curl`, `python-requests`, and `psql`
accept internally issued certificates without `--insecure` — which is what makes
`JENGASEC_DB_SSLMODE=verify-full` usable between Django and PostgreSQL.

**Club laptops and phones will still show a warning.** They do not have the CA.
Distribute `jengasec-ca.crt` to anyone who needs a clean browser, or accept the
warning on internal tooling.

## SANs, not common names

Modern clients ignore the common name entirely and validate against Subject
Alternative Names. A certificate with no SAN is rejected by every current
browser regardless of what its CN says — so `certificates_subject_alt_names` is
set per host in `host_vars` and is the field that actually matters.

```yaml
certificates_subject_alt_names:
  - "DNS:platform.jengasec.local"
  - "DNS:server1.jengasec.local"
  - "IP:10.0.0.11"
```

## The full chain

The role builds `<host>-fullchain.crt` — the host certificate followed by the
CA. nginx needs both in one file. Serving the leaf alone produces
`unable to get local issuer certificate` on any client that does not already
have the CA installed.

Point nginx at the **fullchain**, not the bare `.crt`.

## Let's Encrypt: leave staging on

`certificates_letsencrypt_staging: true` until a certificate is issued
successfully.

The production endpoint rate-limits failed authorisations at five per account
per hostname per hour, and 50 certificates per domain per week. Debugging
against production locks you out for a week, and there is no appeal.

The renewal **deploy hook** is the part people forget: without it the
certificate renews on disk while nginx keeps serving the old one, and you find
out about a month after it expired.

## Variables

| Variable | Default |
|---|---|
| `certificates_provider` | `internal_ca` |
| `certificates_common_name` | `<host>.jengasec.local` |
| `certificates_subject_alt_names` | `[]` — set per host |
| `certificates_key_size` | `4096` |
| `certificates_valid_days` | `365` |
| `certificates_ca_valid_days` | `3650` |
| `certificates_ca_passphrase` | `{{ vault_ca_passphrase }}` — **required** |
| `certificates_install_ca_trust` | `true` |
| `certificates_letsencrypt_staging` | `true` |
| `certificates_generate_dhparam` | `false` — takes minutes of CPU |

## Tags

`certificates`, `packages`, `directories`, `ca`, `host`, `trust`, `verify`,
`letsencrypt`, `dhparam`

## Verifying

```bash
openssl x509 -in /etc/ssl/jengasec/server1.crt -noout -text
openssl x509 -in /etc/ssl/jengasec/server1.crt -noout -dates
openssl verify -CAfile /etc/ssl/jengasec/ca/jengasec-ca.crt \
    /etc/ssl/jengasec/server1.crt
```

The last command must print `OK`. Confirm the SANs are present — a missing SAN
is the single most common reason a certificate that "looks fine" is rejected by
a browser:

```bash
openssl x509 -in /etc/ssl/jengasec/server1.crt -noout -ext subjectAltName
```

Once nginx is serving:

```bash
openssl s_client -connect platform.jengasec.local:443 -servername platform.jengasec.local
```
