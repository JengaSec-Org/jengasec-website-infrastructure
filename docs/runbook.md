# Runbook

How to actually deploy this, phase by phase, and what to do when something
breaks.

---

## 0. Check the repository before you move it

Do this on whichever machine you author on — it needs no Ansible, only
`pyyaml` and `jinja2`:

```bash
pip install pyyaml jinja2
python tests/structure-check.py
```

It parses every YAML file and Jinja2 template, and confirms every variable,
template, role, and handler reference resolves. Catching a missing template here
costs a minute; catching it halfway through a run on real hardware does not.

---

## 1. Get the repository onto the Debian machine

Ansible has no supported Windows control node. The repository is authored on
Windows and **run** from the Debian box.

Via git (preferred — `.gitattributes` handles line endings):

```bash
git clone <your-repo-url> jengasec-website-infrastructure
cd jengasec-website-infrastructure
```

If you copied the folder directly instead — over SMB, a USB stick, or WinSCP —
normalise the line endings first. CRLF in a shell script produces
`bad interpreter: /bin/bash^M`, an error that names the wrong problem:

```bash
sudo apt install dos2unix
find . -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.j2' \) -exec dos2unix {} +
chmod +x scripts/*.sh tests/*.sh
```

Then install the tooling:

```bash
sudo apt update
sudo apt install -y ansible-core git make yamllint python3-argcomplete
ansible-galaxy collection install -r requirements.yml
```

---

## 2. Fill in the inventory

Find everything that still needs a real value:

```bash
grep -rn "TODO: replace" inventories/production/
```

You need, at minimum:

| File | What |
|---|---|
| `hosts.yml` | Each `ansible_host` address, `ansible_user`, key path |
| `host_vars/serverN.yml` | Interface name, address, netmask, gateway, DNS |
| `group_vars/all/main.yml` | Domain, network CIDR, gateway |
| `group_vars/dns/main.yml` | Records, reverse zone, forwarders |

**Check the interface name on the actual machine.** Debian 12 uses predictable
names — `ens18`, `enp0s3`, `eno1` — and it is rarely `eth0`:

```bash
ip -brief link show
```

---

## 3. Secrets and keys

```bash
cp inventories/production/vault.yml.example inventories/production/vault.yml
# edit it with real values
ansible-vault encrypt inventories/production/vault.yml
```

Full workflow in [secrets.md](secrets.md).

Add your SSH public key:

```bash
cp ~/.ssh/id_ed25519.pub roles/users/files/ssh-keys/christine.pub
```

Then list the filename in `group_vars/all/main.yml` under
`users_admin_ssh_keys`. The `users` role **refuses to run** without at least
one, because the `ssh` role that follows disables password authentication.

---

## 4. Preflight

```bash
./scripts/preflight.sh
make lint
make syntax
ansible -i inventories/production all -m ansible.builtin.ping
```

Fix everything preflight reports as an error before continuing.

---

## 5. Dry run

```bash
ansible-playbook -i inventories/development playbooks/bootstrap.yml \
    --check --diff --connection=local
```

The development inventory carries complete variables and dummy secrets, so this
renders every template without a vault password and without touching a server.
It catches undefined variables and broken Jinja2 — the two failures that would
otherwise appear halfway through a real run.

---

## 6. Phase 1 — base OS

Start with **server2 or server3**, not server1. Make your mistakes on the host
you need least.

```bash
make bootstrap LIMIT=server3
```

Then, **from a second terminal, before you close anything**:

```bash
ssh -p 22 jengasec@10.0.0.13
```

If that works, run it again:

```bash
make bootstrap LIMIT=server3
```

**It must report zero changed tasks.** That is the pass criterion for this whole
scaffold. A run that keeps changing things is not describing the system, it is
fighting it — and it means you cannot tell a real change from noise.

Repeat for server2, then server1.

---

## 7. Phase 3 — security

```bash
make security LIMIT=server3
```

Verify:

```bash
sudo aa-status
sudo fail2ban-client status
sudo auditctl -l | wc -l          # must not be 0
```

---

## 8. Phase 2 — networking

> **Have console access open** — physical, iDRAC/iLO, or the hypervisor console.
> This phase can end your SSH session.

`networking_configure` defaults to `false`. If the servers already have working
static addresses from the Debian installer, you can reasonably leave it that way
and only apply the firewall:

```bash
ansible-playbook -i inventories/production playbooks/networking.yml \
    --limit server3 --tags firewall
```

To apply full network configuration, set `networking_configure: true` in that
host's `host_vars`, then:

```bash
make networking LIMIT=server3
```

Immediately afterwards, from a second terminal:

```bash
ssh -p 22 jengasec@10.0.0.13
sudo ufw status verbose
ip -brief addr show
```

Then DNS, on server2:

```bash
make networking LIMIT=server2 --tags dns
dig @10.0.0.12 platform.jengasec.local
dig @10.0.0.12 debian.org
dig @10.0.0.12 jengasec.local AXFR       # MUST be refused
```

**server1 last.**

---

## 9. Before the competition

```yaml
# group_vars/all/main.yml
audit_immutable: true
users_ssh_exclusive: true
```

Then re-run Phase 3 and **reboot** — immutable audit rules only take effect
after a restart.

`users_ssh_exclusive` removes any SSH key not in this repository. Only turn it
on once every current member's key is committed.

---

## Changing the SSH port

The order is fixed. Doing step 2 before step 1 locks you out.

```bash
# 1. Open the new port while 22 is still open
#    (set ssh_port in group_vars, add the rule, apply firewall only)
ansible-playbook -i inventories/production playbooks/networking.yml --tags firewall

# 2. Move sshd
ansible-playbook -i inventories/production playbooks/bootstrap.yml --tags ssh

# 3. From a SECOND terminal, prove it works — do not skip this
ssh -p 2222 jengasec@server1

# 4. Only now remove the port 22 rule and re-run the firewall role
```

---

## Recovery

### Locked out by SSH

Console in, then:

```bash
ls -t /etc/ssh/sshd_config.*                       # the role keeps backups
sudo cp /etc/ssh/sshd_config.<timestamp> /etc/ssh/sshd_config
sudo systemctl reload ssh
sudo journalctl -u ssh -n 50
```

### Locked out by the firewall

```bash
sudo ufw disable
sudo ufw allow 22/tcp
sudo ufw enable
```

Then work out which rule was missing before running the role again.

### Locked out by fail2ban

You banned yourself with a mistyped password, because `fail2ban_ignoreip` does
not cover the address you are coming from.

```bash
sudo fail2ban-client set sshd unbanip <your-address>
sudo fail2ban-client unban --all
```

Then add that address to `fail2ban_ignoreip`.

### Network unreachable after the networking role

```bash
sudo ifdown eth0 --force
sudo mv /etc/network/interfaces.d/50-jengasec.cfg /root/
sudo ifup eth0
```

### DNS is down and nothing resolves

```bash
sudo named-checkconf -z
sudo journalctl -u named -n 50
```

Zone files are written with `backup: true`, so the previous version is beside
the current one with a timestamp. The other servers have static `/etc/hosts`
entries for each other precisely so a DNS outage is not also an application
outage.

### A run half-completed and the state is unclear

Re-run it. Every role in this repository is idempotent — that is what the
"second run reports zero changes" rule buys you. Re-running is the normal
recovery action, not a risk.

---

## Routine operations

```bash
make check                                    # dry run everything
make bootstrap LIMIT=server1                  # re-apply Phase 1 to one host
ansible-playbook -i inventories/production playbooks/bootstrap.yml --tags motd
ansible -i inventories/production all -m ansible.builtin.ping
ansible -i inventories/production all -a "uptime"
ansible -i inventories/production all -a "df -h /" 
make vault-edit
```

## Adding a new server

1. Add it to `inventories/production/hosts.yml`, in the right function groups.
2. Create `host_vars/<name>.yml` — copy an existing one.
3. Add its DNS records to `group_vars/dns/main.yml`.
4. `./scripts/preflight.sh`
5. `make bootstrap LIMIT=<name>` — twice.
6. `make security LIMIT=<name>`
7. `make networking LIMIT=<name>` with console access open.
