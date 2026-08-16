# `cloudflare`

**Phase 9 · Implemented, disabled by default**

Cloudflare Tunnel and Access — how the platform becomes reachable off campus.

## Why a tunnel and not an open port

`cloudflared` dials **out** to Cloudflare and holds the connection open.
Requests arrive down that existing connection. Nothing inbound is needed.

| | |
|---|---|
| The origin's address never appears in public DNS | Nothing to scan for |
| A campus firewall blocking inbound stops mattering | Most block it, and you will not get an exception |
| Cloudflare's WAF and rate limiting sit in front | Free tier, and it absorbs the noise |

That is why `group_vars/web` now closes 80 and restricts 443 to the LAN. The
origin is invisible to the internet; on-campus users still reach nginx directly,
which is faster and survives Cloudflare being unreachable.

## Prerequisites Ansible cannot create

Four things must exist in Cloudflare **before** this role can do anything:

1. A Cloudflare account, and a **real domain** added as a zone
2. A tunnel — Zero Trust → Networks → Tunnels → Create
3. The tunnel token, into the vault as `vault_cloudflare_tunnel_token`
4. A DNS record for the public hostname, pointing at the tunnel

`docs/runbook.md` walks through these. The role asserts each and fails with the
exact step rather than a confusing downstream error.

> **`jengasec.local` cannot be used.** `.local` is reserved for mDNS and
> Cloudflare will not serve it. The role refuses a `.local` domain outright,
> because the failure at Cloudflare's end is opaque.

## Split-horizon naming

Two names for one platform, and both work:

| Name | Reaches it via | Resolved by |
|---|---|---|
| `platform.jengasec.local` | nginx directly, on the LAN | Bind9 |
| `platform.jengasec.example` | the tunnel, from anywhere | Cloudflare |

Both are in nginx's `server_name`, Django's `ALLOWED_HOSTS`, and
`CSRF_TRUSTED_ORIGINS`. Set the public one once, in `jengasec_public_domain`.

## The origin hop is HTTPS

cloudflared connects to `https://127.0.0.1:443`, not plain HTTP.

Both are on the same host so nothing crosses a wire — but HTTPS reuses the
certificate the `certificates` role already issues, and avoids adding a
loopback-only HTTP listener with its own server block.

Two details that make it work:

- **`originServerName`** must be the *internal* name, because that is what the
  certificate is issued for. Without it, SNI does not match, nginx serves the
  default vhost, and verification fails.
- **`caPool`** points at the internal CA so cloudflared can actually verify.
  `noTLSVerify` is the alternative — encryption without authentication, nearly
  harmless on loopback and still the wrong habit.

## The catch-all rule is not optional

`cloudflared` **refuses to start** without a final ingress rule that has no
hostname, and the error it prints does not mention ingress at all.

The template always appends `service: http_status:404`. Anything not matched —
a scan for a hostname we do not serve, a stale DNS record — gets a 404 instead
of reaching nginx.

Test the rules without deploying:

```bash
cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
cloudflared tunnel --config /etc/cloudflared/config.yml ingress rule \
    https://platform.jengasec.example/admin/
```

## Access on `/admin/`

An identity check at Cloudflare's edge, **before** a request reaches Django.

`/admin/` controls every score. With the platform on the internet, Django's
login form is otherwise the only thing between an attacker and the scoring data.
Access means a stolen password alone is not enough — the visitor must also prove
an identity Cloudflare recognises.

Free for up to 50 users on Zero Trust.

The role creates the application and policy through the API rather than leaving
it as a dashboard chore nobody does. That needs a **second, different token**:
the tunnel token has no Access rights.

| Vault key | Permission |
|---|---|
| `vault_cloudflare_tunnel_token` | The tunnel itself |
| `vault_cloudflare_api_token` | Access: Apps and Policies — **Edit** |
| `vault_cloudflare_account_id` | Dashboard, right-hand sidebar |

If the credentials are missing the role **fails with the dashboard steps**
rather than skipping. Leaving `/admin/` on the public internet behind only a
Django password should be a deliberate choice, not an omission.

> **Test Access from a logged-out browser before the competition.** A policy
> that excludes the organisers locks them out of scoring, and the fix is in
> Cloudflare's dashboard — not somewhere you can reach with Ansible while
> everyone is waiting.

## Variables

| Variable | Default |
|---|---|
| `cloudflare_enabled` | `false` |
| `cloudflare_mode` | `tunnel` — only mode implemented |
| `cloudflare_public_domain` | `jengasec.example` — **TODO** |
| `cloudflare_origin_url` | `https://127.0.0.1:443` |
| `cloudflare_origin_no_tls_verify` | `false` |
| `cloudflare_ha_connections` | `4` |
| `cloudflare_access_enabled` | `true` |
| `cloudflare_access_allowed_email_domain` | `strathmore.edu` |
| `cloudflare_access_session_duration` | `8h` |
| `cloudflare_manage_dns` | `false` — the record is made with the tunnel |

## Tags

`cloudflare`, `packages`, `config`, `service`, `access`, `verify`

## Verifying

```bash
sudo systemctl status cloudflared
curl -s localhost:2000/ready
sudo journalctl -u cloudflared -n 50
```

Then from **off campus** — a phone on mobile data is the honest test:

```bash
curl -I https://platform.jengasec.example/healthz/
```

And confirm the origin is genuinely not reachable directly, which is the whole
point:

```bash
curl --connect-timeout 5 https://<server1-public-address>/    # must time out
```

## If it does not work

**Tunnel will not register.** Usually a token for a tunnel that was deleted and
recreated, or no outbound UDP 7844. Set `cloudflare_protocol: http2` to fall
back to TCP 443 if the campus blocks QUIC.

**502 from Cloudflare.** The tunnel is up but the origin is not. A registered
tunnel with a dead origin returns 502 to every visitor — the role checks the
origin separately for exactly this reason.

**525 or 526.** TLS between cloudflared and nginx failed. Almost always
`originServerName` not matching the certificate.

**Everyone locked out of `/admin/`.** The Access policy. Fix it in Zero Trust →
Access → Applications, or set `cloudflare_access_enabled: false` and re-run to
remove the requirement.
