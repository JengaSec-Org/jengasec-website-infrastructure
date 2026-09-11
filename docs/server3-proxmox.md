# Server 3 — v1 on Proxmox

Runbook for standing the whole platform up as one VM on the Kindaruma lab's Server 3.
The baseline survey this builds on is `Server3_Baseline_Inventory.docx` (rev 1.0, 2 Sep 2026).

## Context

Server 3 (`netadmin`, Proxmox VE 9.1, `192.168.40.7/24`, 125 GiB RAM, 2 TB thin pool, zero
guests) is the only machine with internet. The goal is to bring the **whole JengaSec platform
(v1)** up on it.

What changed since the baseline survey:
- The iDRAC and the host were both on `.7`; the iDRAC has been moved and SSH to Proxmox works
  from the laptop (`ssh root@192.168.40.7`). SSH only works from inside the rack switch, so it's a
  convenience, not a remote path.
- DNS is working again: the original resolver `192.168.43.5` now answers. **Keep it**, with
  `8.8.8.8` as backup. No manual BIND on the hypervisor — the repo's `dns` role installs BIND9
  inside a VM as part of Phase 2, which is where it belongs.

The repo (`roles/`, `docs/lab-setup.md`, `README.md`) is written for **Debian 12 (Bookworm)**
guests, a sudo user `jengasec` with no root password, `ufw`, a swap *file*, and a separate Debian
control node. The plan reproduces exactly that on Proxmox instead of VirtualBox, so every doc in
the repo still applies verbatim. Nothing runs on the hypervisor itself.

**Decision: ONE Debian 12 QEMU VM carries everything for v1** — web, database, DNS, backup,
monitoring, *and* it is its own Ansible control node (`ansible_connection: local`). Replicate onto
more VMs later by cloning the template and editing `hosts.yml`; nothing else changes because the
roles target groups, not machines. A VM rather than LXC because the `os` role sets sysctls and a
swap file and `firewall` uses ufw — awkward or impossible in an unprivileged container.

| VM ID | Name | Inventory groups | vCPU | RAM | Disk | IP |
|---|---|---|---|---|---|---|
| 100 | `template-debian12` | — (kept for cloning later) | 2 | 2 GB | 20 GB | DHCP during build only |
| 101 | `jengasec` | infra, web, database, dns, backup, monitoring, monitored | 4 | 8 GB | 60 GB | `192.168.40.11` |

Check `.11` is free first: `ping -c1 192.168.40.11` from the host should get *no* reply.

One consequence of colocating every group on a single host: `firewall_rules_group` is defined in
**seven** `group_vars/*/main.yml` files, and Ansible keeps only one of them (group precedence — the
others are silently dropped). Stage 6 sets `firewall_rules_host` in `host_vars/jengasec.yml` to the
union of every port the box serves, which is the mechanism `roles/firewall` already provides for
this (`firewall_rules_merged = common + group + host`, `roles/firewall/tasks/main.yml:26`).

---

## Stage 1 — Hypervisor prep (over SSH as root@192.168.40.7)

Persist the working resolver through Proxmox (it rewrites `/etc/resolv.conf` otherwise):

```bash
pvesh set /nodes/netadmin/dns --search cns --dns1 192.168.43.5 --dns2 8.8.8.8
getent hosts deb.debian.org
```

Fix apt (enterprise repo 401s without a subscription):

```bash
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
mv /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.disabled 2>/dev/null
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update && apt full-upgrade -y
```

Close the survey gaps and confirm time sync now that DNS works:

```bash
pct list
systemctl restart chrony && sleep 5 && chronyc tracking && timedatectl
```

## Stage 2 — Download the Debian 12 netinst ISO onto the host

```bash
cd /var/lib/vz/template/iso
BASE=https://cdimage.debian.org/cdimage/archive
VER=$(curl -s $BASE/ | grep -o '12\.[0-9]*\.[0-9]*' | sort -V | tail -1); echo "Debian $VER"
wget "$BASE/$VER/amd64/iso-cd/debian-$VER-amd64-netinst.iso"
wget -q "$BASE/$VER/amd64/iso-cd/SHA256SUMS" && sha256sum -c --ignore-missing SHA256SUMS
ls -la /var/lib/vz/template/iso/
```

`current/` on cdimage.debian.org is Debian 13 now, so Debian 12 comes from the archive tree.

## Stage 3 — Build the template VM (ID 100)

```bash
ISO=$(ls /var/lib/vz/template/iso/debian-12.*-netinst.iso | head -1)
qm create 100 --name template-debian12 --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --cores 2 --memory 2048 \
  --scsihw virtio-scsi-single --scsi0 local-lvm:20,discard=on,ssd=1 \
  --net0 virtio,bridge=vmbr0 \
  --ide2 "local:iso/$(basename $ISO),media=cdrom" --boot order='ide2;scsi0' \
  --agent enabled=1 --serial0 socket --vga std
qm start 100
```

Open the console from the laptop: **https://192.168.40.7:8006** → VM 100 → *Console*. Walk the
Debian installer exactly as `docs/lab-setup.md` §2 says:

| Prompt | Answer |
|---|---|
| Hostname | `template` |
| Domain | `jengasec.local` |
| Root password | **leave blank** (puts `jengasec` in sudo — the roles depend on this) |
| User | `jengasec` |
| Partitioning | Guided, entire disk, all files in one partition |
| Software | **only** *SSH server* + *standard system utilities* |

The interface will be **`enp0s18`** on Proxmox (not `enp0s3`) — that's the value for
`networking_interface` later. Installer uses DHCP; static addresses are set per clone.

After first login inside the VM:

```bash
sudo apt update && sudo apt install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent
sudo apt clean && sudo rm -f /etc/ssh/ssh_host_* && sudo truncate -s0 /etc/machine-id && sudo poweroff
```

(Removing host keys and machine-id makes each clone regenerate its own — otherwise all four VMs
share an SSH identity and the DHCP server hands them the same lease.)

Then on the host, detach the ISO and convert to a template:

```bash
qm set 100 --ide2 none --boot order=scsi0
qm template 100
```

## Stage 4 — Clone the one production VM and give it a static IP

```bash
qm clone 100 101 --name jengasec --full
qm set 101 --cores 4 --memory 8192 --onboot 1
qm resize 101 scsi0 60G
qm start 101
```

On the VM via its Proxmox console:

```bash
sudo hostnamectl set-hostname jengasec
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 jengasec.jengasec.local jengasec/' /etc/hosts
sudo tee /etc/network/interfaces.d/enp0s18 >/dev/null <<'EOF'
auto enp0s18
iface enp0s18 inet static
    address 192.168.40.11/24
    gateway 192.168.40.1
    dns-nameservers 192.168.43.5 8.8.8.8
    dns-search jengasec.local
EOF
sudo sed -i 's/^\(auto\|iface\|allow-hotplug\) enp0s18.*/# &/' /etc/network/interfaces
sudo dpkg-reconfigure -f noninteractive openssh-server
sudo systemd-machine-id-setup
sudo reboot
```

Post-reboot check: `ip -br a` shows `192.168.40.11`, `ping -c1 deb.debian.org` works,
`ip route show default` shows exactly one route. The disk resize is picked up automatically on
Debian 12 with a single-partition layout; verify with `df -h /` (~58G). If not:
`sudo apt install -y cloud-guest-utils && sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2` (root is `sda2`; `sda1` is the EFI partition — check with `lsblk`).

Snapshot from the host once it's networked — every rebuild starts here:

```bash
qm snapshot 101 networked
```

## Stage 5 — The VM is its own control node

`ssh netadmin@192.168.40.11` from the laptop (the installer account), then:

```bash
sudo apt install -y ansible-core git make python3-jinja2 python3-yaml
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
git clone https://github.com/JengaSec-Org/jengasec-website-infrastructure.git
cd jengasec-website-infrastructure
ansible-galaxy collection install -r requirements.yml
```

## Stage 6 — Inventory

Already in the repo: `inventories/v1/` — one host `jengasec` in every group, `ansible_connection:
local`, the lab network, loopback-bound PostgreSQL/Redis, and the union of every group's firewall
rules in `host_vars/jengasec.yml` (only one `firewall_rules_group` survives Ansible precedence when
a host is in seven groups — read the comment there before adding ports to a group file).

Two things it cannot contain:

1. **Your SSH public key.** Copy it to `files/ssh-keys/jengasec-admin.pub` (the name listed in
   `group_vars/all/main.yml` → `users_admin_ssh_keys`). The `users` role refuses to run without
   one, because the `ssh` role then disables password login.
2. **The vault.** `cp inventories/v1/vault.yml.example inventories/v1/vault.yml`, fill in real
   values (`docs/secrets.md`), `ansible-vault encrypt` it, and create `.vault_pass`.

Then validate before touching the host:

```bash
export INVENTORY=inventories/v1
make structure && make syntax && make preflight && make ping
```

## Stage 7 — Deploy, in phase order (on the VM, `INVENTORY=inventories/v1`)

```bash
make bootstrap      # Phase 1 — base OS
make networking     # Phase 2 — static net, BIND9, ufw. Read docs/runbook.md first: it can drop SSH — keep the Proxmox console open
make security       # Phase 3
make database       # Phase 5 — PostgreSQL
make platform       # Phase 4 — Redis, gunicorn, Django, nginx
make monitoring     # Phase 7 — Prometheus/Grafana
make backup         # Phase 10 — backs up to itself for now; a real target is a v2 item
make deploy REV=<tag>
```

Run `make check` (dry run) before each real phase the first time through. `make networking` is the
one to watch: with `ansible_connection: local` it can't drop your Ansible session, but it rewrites
the VM's `/etc/network/interfaces` — that's why Stage 4 put the static config in
`interfaces.d/enp0s18` matching what the role will write, and why the `networked` snapshot exists.

`make cloudflare` (Phase 9, internet exposure) is deliberately **not** in v1 — it needs a Cloudflare
account/zone/token and the runbook says so.

## Stage 8 — Reach it from off campus (Tailscale)

Everything above only works from inside the rack switch. This stage makes the VM — and, through
it, the Proxmox UI on `.7:8006` — reachable from anywhere, with no inbound port and **nothing
installed on the hypervisor**: the VM joins a Tailscale tailnet and advertises `192.168.40.0/24`
as a subnet route. `inventories/v1` already has `tailscale_enabled: true`; what it cannot contain
is the account. Full walk-through in `docs/runbook.md` §9b, in short:

1. Tailscale account → Access Controls: declare `tag:jengasec-server` (runbook has the policy).
2. Settings → Keys → Generate auth key: reusable off, pre-approved on, tag `tag:jengasec-server`.
   Into the vault as `vault_tailscale_auth_key`.
3. On the VM: `make tailscale INVENTORY=inventories/v1`. Run it **after** `make networking` so
   the `tailscale0` firewall rules are applied (or run it again afterwards).
4. Admin console → Machines → `jengasec` → Edit route settings → approve `192.168.40.0/24`.
5. Install the Tailscale app on the laptop and phone, sign in, and from mobile data:
   `ssh jengasec@jengasec` and `https://192.168.40.7:8006`.

This is admin access. It does not replace the Cloudflare tunnel for competitors — a tailnet is a
private network, and everyone on it can reach the whole lab once the route is approved, which is
why the ACL in step 1 matters.

## Verification

| Check | Where | Expected |
|---|---|---|
| Guests up | host: `qm list` | 101 running, 100 stopped (template) |
| Reachability | VM: `make ping` | `pong` |
| Internal DNS | VM: `dig @127.0.0.1 platform.jengasec.local +short` | `192.168.40.11` |
| Site | laptop: `curl -k https://192.168.40.11/` | nginx/Django response |
| DB | VM: `sudo -u postgres psql -c '\l'` | jengasec database listed |
| Monitoring | laptop: `http://192.168.40.11:3000` | Grafana login |
| Firewall | VM: `sudo ufw status` | 22, 80, 443, 53, 3000, 9090 listed — all of them, not one group's |
| Idempotent | VM: `make site` second run | no `changed` tasks |
| Tailnet | VM: `sudo tailscale status` | `jengasec` with a `100.x` address, no "route not approved" warning |
| Off campus | phone on mobile data: `https://192.168.40.7:8006` | Proxmox login, via the subnet route |

## Warnings

1. **Never run `make networking` against the Proxmox host** — `roles/networking` rewrites
   `/etc/network/interfaces` and would destroy `vmbr0`. The host is not in any inventory; keep it
   that way.
2. Proxmox firewall is off and nftables empty on the host. Ports 8006/22/3128/111 are open to the
   whole lab segment. Acceptable for v1, but a datacenter-level firewall rule allowing 8006/22 from
   the laptop's address only is a five-minute follow-up.
3. Single 1 GbE link, single disk, no backup target on the host (§5.4, §6.6 of the baseline).
   v1 lives on one spindle — `make backup` covers the data, not the hypervisor.
4. Once the subnet route is approved, **every device on the tailnet can reach 8006 on the host**
   — the Proxmox firewall is off (warning 2). The tailnet ACL and the list of invited users are
   what limit that, so keep the ACL tight and do not hand out the auth key.
5. Debian 12 is what the roles were written against. Do not "upgrade" the template to 13 to match
   the host — Python 3.13 and package renames would surface as role failures with no upside.
