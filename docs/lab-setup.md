# Lab setup — four VirtualBox VMs

Run the whole thing on a laptop before it touches real hardware.

This is the honest way to find out what actually works. Everything up to now has
been *structurally* verified — the YAML parses, every variable resolves — but no
role has run against a live Debian host. Some of them will be wrong. Finding out
here is free.

**Budget:** four VMs, about 5.5 GB of RAM, 85 GB of disk, an evening.

---

## What you are building

```
        Windows host  192.168.56.1
             │
   ┌─────────┴──── vboxnet0, host-only, 192.168.56.0/24 ────────────┐
   │              │              │                    │
control          server1        server2             server3
.10              .11            .12                 .13
1 GB             1.5 GB         1.5 GB              1.5 GB
Ansible          nginx          PostgreSQL          Prometheus
                 gunicorn       Redis               Grafana
                 Django         Bind9               backups
   │              │              │                    │
   └──────── each also has a NAT adapter for internet ─┘
```

### Why two adapters

VirtualBox's plain **NAT is per-VM and isolated** — with only that, the VMs
cannot see each other at all, and this whole exercise is about the parts that
span hosts.

**Host-only** gives them a shared network with the host, but no internet, so
`apt` fails.

So: **NAT for internet, host-only for the lab network.** Every VM gets both.

The default route belongs to the NAT adapter. The host-only interface gets
**no gateway** — putting one on both gives the host two default routes, and the
symptom is apt breaking after a reboot with nothing in the logs pointing at the
network. The lab inventory sets `networking_gateway: ""` for exactly this.

---

## 1. The host-only network

VirtualBox → **File → Tools → Network Manager → Host-only Networks**.

There is usually a `vboxnet0` already. Confirm or set:

| | |
|---|---|
| IPv4 address | `192.168.56.1` |
| Mask | `255.255.255.0` |
| DHCP Server | **Enabled** — needed for the first boot, before static addresses exist |

> VirtualBox 7 only allows host-only networks inside `192.168.56.0/21` unless
> you edit `/etc/vbox/networks.conf`. Staying on `192.168.56.x` avoids a
> confusing "invalid host-only address" refusal.

---

## 2. Build the first VM

Build **one** properly, then clone it. Installing Debian four times is an hour
you do not need to spend.

Download the Debian 12 **netinst** ISO (~630 MB).

**New VM:**

| Setting | Value |
|---|---|
| Type | Linux / Debian (64-bit) |
| Memory | 1536 MB |
| CPUs | 2 |
| Disk | 20 GB, VDI, dynamically allocated |
| Adapter 1 | **NAT** |
| Adapter 2 | **Host-only**, `vboxnet0` |

Both adapters matter. Set them before first boot.

### Debian install

Mostly defaults. What matters:

| Prompt | Answer |
|---|---|
| Primary network interface | **enp0s3** — the NAT one, so the installer has internet |
| Hostname | `server1` (you will change it per clone) |
| Domain | `jengasec.lab` |
| Root password | **Leave blank.** Debian then puts your user in sudo, which is what the roles expect |
| User | `jengasec` |
| Partitioning | Guided, entire disk, all files in one partition |
| Software selection | Untick everything except **SSH server** and **standard system utilities** |

Unticking the desktop matters — it is the difference between a 1.5 GB VM that
works and one that swaps constantly.

### Before cloning

Log in and:

```bash
sudo apt update && sudo apt install -y qemu-guest-agent
sudo systemctl poweroff
```

Then **take a snapshot** called `clean-install`. Every rebuild starts here.

---

## 3. Clone to four

Right-click the VM → **Clone**:

- **Full clone** — linked clones share a disk, and you want these independent
- **Generate new MAC addresses for all network adapters** — miss this and two
  VMs get the same host-only address

Make `server2`, `server3`, and `control`.

Give `control` **1024 MB** and `server3` a **25 GB** disk — it holds both the
Prometheus database and every backup.

### On each clone

Boot it, log in, and fix the identity plus bring up the host-only interface.
This is the one manual step: the Debian installer only configures the primary
interface, so `enp0s8` comes up with no address and Ansible cannot reach it.

```bash
# 1. hostname — replace with server2 / server3 / control
sudo hostnamectl set-hostname server2
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 server2.jengasec.lab server2/' /etc/hosts

# 2. confirm the interface name. Assume nothing.
ip -brief link show

# 3. host-only address — replace .12 with .11 / .13 / .10
sudo tee /etc/network/interfaces.d/60-hostonly.cfg >/dev/null <<'EOF'
auto enp0s8
iface enp0s8 inet static
    address 192.168.56.12
    netmask 255.255.255.0
    # No gateway. The default route belongs to enp0s3 (NAT).
EOF

sudo ifup enp0s8
sudo reboot
```

After the reboot, check both networks work:

```bash
ip -brief addr show          # enp0s3 has a NAT address, enp0s8 has 192.168.56.x
ping -c1 192.168.56.1        # the host
ping -c1 deb.debian.org      # the internet, via NAT
ip route show default        # EXACTLY ONE default route, via enp0s3
```

That last check is the one worth doing. Two default routes is the failure this
layout is designed to avoid.

**Snapshot each VM as `networked`.**

---

## 4. Set up the control node

On `control` only:

```bash
sudo apt update
sudo apt install -y ansible-core git make yamllint python3-jinja2 python3-yaml
ansible-galaxy collection install -r requirements.yml
```

Get the repository across. Simplest is a shared folder or `scp` from Windows;
cleanest is git if you have pushed it.

```bash
# from Windows, if you have not pushed:
scp -r "D:\school\Club work\JengaSec\Jengasec app\jengasec-website-infrastructure" \
    jengasec@192.168.56.10:~/
```

If you copy rather than clone, **normalise the line endings** — CRLF in a shell
script produces `bad interpreter: /bin/bash^M`, an error that names the wrong
problem:

```bash
sudo apt install -y dos2unix
cd ~/jengasec-website-infrastructure
find . -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.j2' \) -exec dos2unix {} +
chmod +x scripts/*.sh tests/*.sh
```

### The SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C 'lab-control'
cp ~/.ssh/id_ed25519.pub roles/users/files/ssh-keys/lab-control.pub
```

The lab inventory already expects `lab-control.pub`.

Copy it to the three servers so Ansible can get in the first time:

```bash
for h in 11 12 13; do ssh-copy-id jengasec@192.168.56.$h; done
```

### The vault

```bash
cp inventories/lab/vault.yml.example inventories/lab/vault.yml
ansible-vault encrypt inventories/lab/vault.yml
echo 'your-vault-password' > .vault_pass && chmod 600 .vault_pass
```

Then uncomment `vault_password_file` in `ansible.cfg`.

### The backup GPG key

The backup role is on in the lab, and it needs a public key:

```bash
gpg --batch --gen-key <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: JengaSec Lab Backups
Name-Email: backups@jengasec.lab
Expire-Date: 0
%no-protection
EOF

gpg --armor --export backups@jengasec.lab > roles/backup/files/jengasec-backup.pub.asc
```

`%no-protection` is fine **in a lab**. In production the private key is
passphrase-protected and lives nowhere near the backup host.

### Check before you start

```bash
python3 tests/structure-check.py
make lint INVENTORY=inventories/lab
ansible -i inventories/lab all -m ansible.builtin.ping
```

All three should pass before you run a single role.

---

## 5. Snapshot discipline

**This is what makes the lab worth doing.** Take a snapshot of all three servers
before each phase. When a role locks you out — and one will — you roll back in
seconds instead of rebuilding.

VirtualBox does not snapshot groups, so either click through three VMs or:

```powershell
# Windows PowerShell
$vbox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
foreach ($vm in "server1","server2","server3") {
    & $vbox snapshot $vm take "before-security" --pause
}
```

Suggested points: `networked` → `phase1` → `phase3` → `phase2` → `phase5` →
`phase4` → `phase7` → `phase10`.

---

## 6. Run it

```bash
cd ~/jengasec-website-infrastructure
export INV=inventories/lab

# Phase 1 — base OS
ansible-playbook -i $INV playbooks/bootstrap.yml --limit server3
ansible-playbook -i $INV playbooks/bootstrap.yml --limit server3   # again: zero changes
```

**Run every phase twice.** The second run must report **zero changed tasks**.
That is the pass criterion for this whole repository, and the lab is where you
find out which roles fail it.

Then, in order, each time server3 → server2 → server1:

```bash
ansible-playbook -i $INV playbooks/security.yml   --limit server3
ansible-playbook -i $INV playbooks/networking.yml --limit server3   # firewall + TLS
ansible-playbook -i $INV playbooks/database.yml   --limit server2
ansible-playbook -i $INV playbooks/platform.yml   --limit server1
ansible-playbook -i $INV playbooks/monitoring.yml
ansible-playbook -i $INV playbooks/backup.yml     --limit server3
```

`networking_configure` is **false** by default in the lab, so
`playbooks/networking.yml` applies the firewall, DNS and certificates but leaves
the interface alone. Turn it on later, deliberately, with a snapshot taken —
see section 8.

### The superuser

```bash
ssh jengasec@192.168.56.11
sudo -u jengasec /opt/jengasec/venv/bin/python \
    /opt/jengasec/app/manage.py createsuperuser
```

---

## 7. What to actually check

Not "did it run" — that only proves Ansible finished.

### The database is closed

The single most important rule in the repository, and the lab is where you can
prove it both ways:

```bash
ssh jengasec@192.168.56.11 "nc -zv 192.168.56.12 5432"   # SUCCEEDS
ssh jengasec@192.168.56.13 "nc -zv 192.168.56.12 5432"   # MUST FAIL
```

If the second succeeds, the firewall rule in `group_vars/database` is not doing
its job.

### The platform answers

```bash
ssh jengasec@192.168.56.11
sudo -u www-data curl --unix-socket /run/gunicorn/gunicorn.sock http://localhost/healthz/
curl -k https://192.168.56.11/healthz/
```

The first talks to gunicorn **as nginx's user**, bypassing nginx entirely. If it
works and the second does not, the problem is nginx. If it fails with a
permission error, it is the socket group — the classic 502.

### Rate limiting engages

```bash
for i in $(seq 1 15); do
  curl -ks -o /dev/null -w "%{http_code} " https://192.168.56.11/login/
done
```

Expect `200` a few times, then `429`.

### DNS refuses a transfer

```bash
dig @192.168.56.12 platform.jengasec.lab
dig @192.168.56.12 jengasec.lab AXFR      # MUST say "Transfer failed"
```

If AXFR returns records, anyone on the network can enumerate every host.

### The backup actually restores

The lab exists for this one. Everything else in the backup role is machinery
around it:

```bash
ssh jengasec@192.168.56.13
sudo -u backup /usr/local/sbin/jengasec-backup
ls -la /srv/backup/daily/
sudo -u backup /usr/local/sbin/jengasec-backup-verify
jengasec-restore --list
```

The first run **will fail** on the pull — the forced-command key is not
installed yet. That is expected, and the role prints the line to add. Put it in
`inventories/lab/group_vars/all/main.yml`:

```yaml
users_backup_pull_enabled: true
users_backup_pull_key: "ssh-ed25519 AAAA..."
users_backup_pull_from: "192.168.56.13"
```

Then:

```bash
ansible-playbook -i $INV playbooks/bootstrap.yml --tags backup-key
```

and run the backup again.

### Monitoring sees everything

```bash
curl -s http://192.168.56.13:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
```

Three `"up"`. Any `"down"` means node_exporter is not running there, or the
firewall is blocking server3.

Then open `http://192.168.56.13:3000` from the Windows browser and sign in.

Make an alert fire, so you know the alerting works:

```bash
ssh jengasec@192.168.56.13 "dd if=/dev/zero of=/tmp/fill bs=1M count=1500"
# watch DiskSpaceLow in the Prometheus UI, then:
ssh jengasec@192.168.56.13 "rm /tmp/fill"
```

---

## 8. The dangerous roles — do these last, on purpose

The lab is the only place you get to be locked out for free. **Snapshot first**,
then try each one and watch what happens.

### `networking`

```yaml
# host_vars/server3.yml
networking_configure: true
```

```bash
ansible-playbook -i $INV playbooks/networking.yml --limit server3 --tags networking
```

Watch the role assert the interface exists, apply, and ping. Then deliberately
break it — set `networking_interface: eth0` — and confirm the assert catches it
**before** anything is written. That guard is why the role is safe.

### Changing the SSH port

The order is fixed, and getting it wrong is instructive:

```bash
# 1. firewall FIRST, while 22 is still open
#    set ssh_port: 2222 in group_vars/all, then:
ansible-playbook -i $INV playbooks/networking.yml --limit server3 --tags firewall
# 2. then sshd
ansible-playbook -i $INV playbooks/bootstrap.yml --limit server3 --tags ssh
# 3. prove it from a second terminal BEFORE closing anything
ssh -p 2222 jengasec@192.168.56.13
```

Now roll the snapshot back and do it in the wrong order. Locking yourself out
once, on a VM you can restore in ten seconds, is worth more than reading about
it.

### `audit_immutable`

```yaml
audit_immutable: true
```

Run `security.yml`, reboot, then try to change an audit rule. `auditctl` refuses
until the next reboot — which is the whole point, and worth seeing once.

### The Cloudflare tunnel

Works fine from a lab VM, and does not need the campus network. You need a real
domain in a Cloudflare account and a **separate** tunnel from any production
one. Follow `docs/runbook.md` step 9 with `cloudflare_enabled: true` in
`group_vars/web`.

The satisfying part: `curl` your public hostname from a phone on mobile data and
watch it reach a VM on your laptop through a firewall you never opened.

---

## What the lab will not tell you

Worth being clear about, so you do not over-trust a green run:

| | |
|---|---|
| **Performance** | 1.5 GB VMs on one disk. Nothing here predicts behaviour under competition load. |
| **The 8 GB / 4 GB tuning** | Lab values are deliberately different. `shared_buffers` is 256 MB here and 1 GB in production — the *fraction* carries across, not the number. |
| **Real network conditions** | No campus firewall, no VLANs, no other DHCP server, no latency. |
| **Cloudflare Access** | Needs a Zero Trust account. The tunnel is testable here; the Access policy really needs a second person to try logging in. |
| **Disk exhaustion over time** | Journal growth, backup accumulation and Prometheus retention all take weeks to show. |

What it **does** tell you: whether the roles run, whether they are idempotent,
whether the guards fire, whether the services actually come up and talk to each
other — and whether a restore works. That is most of the risk.

---

## Rebuilding

```powershell
$vbox = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
foreach ($vm in "server1","server2","server3") {
    & $vbox controlvm $vm poweroff 2>$null
    & $vbox snapshot  $vm restore "networked"
    & $vbox startvm   $vm --type headless
}
```

Headless is worth it — three GUI windows for servers you only reach over SSH is
just RAM you could give the VMs.
