# A browser-trusted certificate for jengasec.com names

The VM serves HTTPS with a certificate from its own internal CA, which every
browser warns about. A certificate from a public CA — free from Let's Encrypt,
or bought (Namecheap resells Sectigo PositiveSSL) — is trusted by every
browser with no warning, **for the names it was issued for, and only where
those names lead to the VM.**

## No certificate yet? A free one from Let's Encrypt

You own `jengasec.com` at Namecheap, and that is enough. Let's Encrypt
normally checks a file on your web server — impossible here, the VM is not
reachable from the internet — but it can check a **DNS TXT record** instead,
which you add at Namecheap. Free, trusted by every browser, valid 90 days.

**1. Pick the name** people will type, e.g. `venue.jengasec.com`, and point it
at the VM: Namecheap → Domain List → `jengasec.com` → Manage → **Advanced DNS**
→ Add New Record → **A Record**, host `venue`, value `192.168.40.11`.

**2. Ask for the certificate**, on the website VM:

```bash
sudo apt install -y certbot
```
```bash
sudo certbot certonly --manual --preferred-challenges dns -d venue.jengasec.com -m sucybersec@strathmore.edu --no-eff-email
```

It asks you to accept Let's Encrypt's terms (read them; answer `Y` if you
agree), then **stops** and shows something like:

```
Please deploy a DNS TXT record under the name:
_acme-challenge.venue.jengasec.com.
with the following value:
gfj9Xq...Rg85nM
```

**Leave it waiting.** At Namecheap → Advanced DNS → Add New Record →
**TXT Record**: host `_acme-challenge.venue` (Namecheap adds `.jengasec.com`
itself), value the long string, TTL **1 min**. Save.

**3. Wait until the record is visible**, then press Enter in the certbot
window. Check from another terminal — repeat until it prints the string:

```bash
nslookup -type=TXT _acme-challenge.venue.jengasec.com 8.8.8.8
```

(If the campus blocks outside DNS servers, use https://dnschecker.org with
type TXT on your phone.) certbot then reports
`Successfully received certificate` and saves it under
`/etc/letsencrypt/live/venue.jengasec.com/`. The TXT record can be deleted
afterwards.

**4. Switch nginx to it** — in `inventories/v1/group_vars/web/main.yml`:

```yaml
jengasec_custom_domains:
  - "venue.jengasec.com"
nginx_custom_tls_enabled: true
nginx_custom_tls_source: letsencrypt
```

```bash
make platform INVENTORY=inventories/v1 ANSIBLE_ARGS=-K
```

The role checks certbot's files exist, that key and certificate match and
that it has not expired, before nginx is changed. Then check — no `-k`:

```bash
curl -I https://venue.jengasec.com/healthz/
```

**Renewal:** 90 days, so it outlasts the event. To renew, run the same
`certbot certonly` command again (a new TXT value), then
`sudo systemctl reload nginx`. certbot's automatic renewal timer cannot renew
a manual DNS certificate and will log a harmless failure — ignore it.

---

The rest of this page is for a certificate **bought** from Namecheap
(`nginx_custom_tls_source: vault`).

## 1. Know what you have

From Namecheap (SSL Certificates → your certificate → Download), you get:

| File | What it is |
|---|---|
| `your_domain.crt` | the certificate itself |
| `your_domain.ca-bundle` | Sectigo's intermediate certificates |

And from when you **activated** it — generated with the CSR, on your machine
or on Namecheap's CSR page:

| File | What it is |
|---|---|
| `private.key` / `your_domain.key` | the private key. Without it the certificate is useless, and Namecheap cannot send it again |

Which names it covers, and until when (any Linux/WSL/Git Bash shell):

```bash
openssl x509 -in your_domain.crt -noout -subject -ext subjectAltName -enddate
```

`DNS:*.jengasec.com` covers every one-level subdomain (`venue.jengasec.com`)
but not `jengasec.com` itself. `DNS:jengasec.com, DNS:www.jengasec.com` covers
exactly those two.

Check the key belongs to it — the two lines must be identical:

```bash
openssl x509 -in your_domain.crt -noout -pubkey | sha256sum
openssl pkey -in private.key -pubout | sha256sum
```

## 2. Point a name at the VM

The certificate proves who the server is; DNS is what sends people to it.

**A subdomain (simplest)**, e.g. `venue.jengasec.com`, if the certificate covers
it: Namecheap → Domain List → `jengasec.com` → Manage → **Advanced DNS** → Add
New Record → **A Record**, host `venue`, value `192.168.40.11`. Anyone on the
lab network can then open `https://venue.jengasec.com`. Off campus that address
leads nowhere, which is fine — and it does reveal the lab's internal address in
public DNS, which is acceptable for a private-range address.

**`www.jengasec.com` itself**: publicly that name is Render. To send *venue*
devices to the VM instead, the venue's own DNS (OPNsense — ask NET) must answer
`www.jengasec.com → 192.168.40.11 / 10.109.0.10`. Then links in emails work at
the venue too. Do not change it at Namecheap: that would move the public site.

## 3. Put it in the vault

```bash
ansible-vault edit inventories/v1/vault.yml
```

```yaml
vault_custom_tls_fullchain: |
  -----BEGIN CERTIFICATE-----
  (contents of your_domain.crt)
  -----END CERTIFICATE-----
  -----BEGIN CERTIFICATE-----
  (contents of your_domain.ca-bundle — it may hold two certificates; paste all)
  -----END CERTIFICATE-----
vault_custom_tls_key: |
  -----BEGIN PRIVATE KEY-----
  (contents of the private key)
  -----END PRIVATE KEY-----
```

Keep the `|`, and indent every line by two spaces. Domain certificate first,
bundle after — the other order makes some phones reject the site.

## 4. Switch it on

In `inventories/v1/group_vars/web/main.yml`:

```yaml
jengasec_custom_domains:
  - "venue.jengasec.com"        # every name you will type, all covered by the certificate

nginx_custom_tls_enabled: true
```

Then:

```bash
make platform INVENTORY=inventories/v1 ANSIBLE_ARGS=-K
```

Before nginx is touched, the role checks the key matches the certificate and
that it has not expired, and prints the names it covers. Django's allowed hosts
and trusted origins pick the names up from `jengasec_custom_domains`.

## 5. Check

```bash
curl -I https://venue.jengasec.com/healthz/          # no -k: it must be trusted as-is
```

`200`, and no certificate error. Then in a browser: the padlock, no warning.

Addresses and names the certificate does not cover (`https://192.168.40.11`,
`jengasec.range`) still work, with a warning — the certificate cannot cover an
IP address.

## Renewal

PositiveSSL lasts a year. When Namecheap sends the renewed certificate,
replace `vault_custom_tls_fullchain` (and the key, if you made a new CSR) and
run `make platform` again.
