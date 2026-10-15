#!/bin/bash
# One-time setup on the DATABASE VM (postgres-vm: 192.168.40.45, later 10.109.0.20).
#
#     sudo bash setup-database-vm.sh
#
# Creates the website's own database next to the API's, and lets the website
# VM — and only the website VM — connect to it:
#
#   1. role     jengasec_web, with a generated password (printed ONCE)
#   2. database jengasec_web, owned by that role
#   3. pg_hba.conf lines for the website VM's addresses
#   4. checks PostgreSQL listens on the network, and opens 5432 in ufw if
#      ufw is in use
#   5. an hourly backup of jengasec_web into /var/backups/jengasec_web
#      (systemd timer, last 48 dumps kept)
#
# Safe to run again: anything already in place is left alone, and the password
# is only changed if you pass --new-password.
#
# It never touches any other database or role on this server.

set -euo pipefail

DB=jengasec_web
ROLE=jengasec_web
# The website VM: its lab address now, and its VLAN 109 address once that NIC
# exists (JengaSec_VLAN_Ranges.pdf). Override with WEB_VM_IPS="..." if needed.
WEB_VM_IPS="${WEB_VM_IPS:-192.168.40.11 10.109.0.10}"
MARKER="# jengasec-website"

say()  { echo -e "\033[1m==>\033[0m $*"; }
warn() { echo -e "\033[33mWARNING:\033[0m $*"; }
die()  { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }
pg()   { sudo -u postgres psql -XAtq -v ON_ERROR_STOP=1 "$@"; }

[ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0"
command -v psql >/dev/null || die "psql not found — is PostgreSQL installed on this VM?"
pg -c "SELECT 1" >/dev/null || die "Cannot connect as the postgres user. Is PostgreSQL running? (systemctl status postgresql)"

NEW_PASSWORD=false
[ "${1:-}" = "--new-password" ] && NEW_PASSWORD=true

say "PostgreSQL $(pg -c 'SHOW server_version') on $(hostname)"

# ── 1. Role ─────────────────────────────────────────────────────────────────
PASSWORD=""
if [ -z "$(pg -c "SELECT 1 FROM pg_roles WHERE rolname = '$ROLE'")" ]; then
    PASSWORD=$(openssl rand -hex 32)
    # Sent on stdin, not the command line, so it never shows in `ps`.
    pg <<SQL
CREATE ROLE $ROLE LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$PASSWORD';
SQL
    say "Created role $ROLE"
elif $NEW_PASSWORD; then
    PASSWORD=$(openssl rand -hex 32)
    pg <<SQL
ALTER ROLE $ROLE PASSWORD '$PASSWORD';
SQL
    say "Gave role $ROLE a new password"
else
    say "Role $ROLE already exists (password unchanged — rerun with --new-password to replace it)"
fi

# ── 2. Database ─────────────────────────────────────────────────────────────
if [ -z "$(pg -c "SELECT 1 FROM pg_database WHERE datname = '$DB'")" ]; then
    pg -c "CREATE DATABASE $DB OWNER $ROLE"
    say "Created database $DB"
else
    say "Database $DB already exists"
fi

# ── 3. pg_hba.conf ──────────────────────────────────────────────────────────
HBA=$(pg -c "SHOW hba_file")
CHANGED_HBA=false
for ip in $WEB_VM_IPS; do
    line="host    $DB    $ROLE    $ip/32    scram-sha-256    $MARKER"
    if grep -qE "^host[[:space:]]+$DB[[:space:]]+$ROLE[[:space:]]+$ip/32" "$HBA"; then
        say "pg_hba.conf already allows $ip"
    else
        $CHANGED_HBA || cp -a "$HBA" "$HBA.bak-$(date +%Y%m%d-%H%M%S)"
        # Inserted at the TOP: pg_hba.conf is first-match, and a broad
        # `reject` or `md5` line further up would otherwise win.
        sed -i "1i $line" "$HBA"
        CHANGED_HBA=true
        say "pg_hba.conf now allows $ip"
    fi
done

if $CHANGED_HBA; then
    pg -c "SELECT pg_reload_conf()" >/dev/null
    errors=$(pg -c "SELECT line_number || ': ' || error FROM pg_hba_file_rules WHERE error IS NOT NULL")
    [ -z "$errors" ] || die "pg_hba.conf has errors after the change (a backup is next to it):\n$errors"
    say "Reloaded PostgreSQL (nothing already connected was interrupted)"
fi

# The server must store passwords as SCRAM for the scram-sha-256 lines above.
[ "$(pg -c 'SHOW password_encryption')" = "scram-sha-256" ] || \
    warn "password_encryption is not scram-sha-256; the website may fail to log in. Ask whoever set up this server."

# ── 4. Network ──────────────────────────────────────────────────────────────
LISTEN=$(pg -c "SHOW listen_addresses")
case "$LISTEN" in
    "*"|*192.168.40.*|*10.109.*|*0.0.0.0*) say "Listening on: $LISTEN" ;;
    *)
        warn "PostgreSQL only listens on '$LISTEN' — the website VM cannot reach it."
        echo "    Fix:  sudo -u postgres psql -c \"ALTER SYSTEM SET listen_addresses = '*'\""
        echo "          sudo systemctl restart postgresql      # RESTART: briefly interrupts the API too"
        ;;
esac

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for ip in $WEB_VM_IPS; do
        ufw allow from "$ip" to any port 5432 proto tcp comment "jengasec website" >/dev/null
    done
    say "ufw allows 5432 from: $WEB_VM_IPS"
fi

# ── 5. Hourly backups of jengasec_web ───────────────────────────────────────
# Taken HERE, where pg_dump runs as postgres with no password and always
# matches the server's version. One dump per hour, the last 48 kept (two
# days) — during the event the data changes by the minute.
#   list:     ls -lh /var/backups/jengasec_web/
#   restore:  sudo -u postgres pg_restore --clean --if-exists -d jengasec_web <file>
BACKUP_DIR=/var/backups/jengasec_web
install -d -o postgres -g postgres -m 0700 "$BACKUP_DIR"

cat > /usr/local/sbin/jengasec-web-backup <<EOF
#!/bin/bash
# Installed by scripts/cutover/setup-database-vm.sh — hourly dump of $DB.
set -euo pipefail
out="$BACKUP_DIR/$DB-\$(date +%Y%m%d-%H%M).dump"
runuser -u postgres -- pg_dump -Fc "$DB" > "\$out.tmp"
# An empty or tiny file means pg_dump failed after starting — never keep it
# in place of a good one.
[ "\$(stat -c %s "\$out.tmp")" -gt 1024 ] || { rm -f "\$out.tmp"; echo "dump too small" >&2; exit 1; }
mv "\$out.tmp" "\$out"
chown postgres:postgres "\$out"; chmod 0600 "\$out"
ls -1t "$BACKUP_DIR"/$DB-*.dump | tail -n +49 | xargs -r rm -f
echo "saved \$out (\$(du -h "\$out" | cut -f1))"
EOF
chmod 0750 /usr/local/sbin/jengasec-web-backup

cat > /etc/systemd/system/jengasec-web-backup.service <<EOF
[Unit]
Description=Hourly dump of the JengaSec website database ($DB)
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/jengasec-web-backup
EOF

cat > /etc/systemd/system/jengasec-web-backup.timer <<EOF
[Unit]
Description=Dump $DB every hour

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now jengasec-web-backup.timer >/dev/null
say "Hourly backups of $DB to $BACKUP_DIR (last 48 kept) — next: $(systemctl show jengasec-web-backup.timer -p NextElapseUSecRealtime --value)"

# ── Result ──────────────────────────────────────────────────────────────────
echo
say "Done."
if [ -n "$PASSWORD" ]; then
    MY_IP=$(hostname -I | awk '{print $1}')
    echo
    echo "  The website's database URL — put it in the vault on the WEBSITE VM as"
    echo "  vault_jengasec_db_url. It is shown ONCE; it is not stored anywhere here:"
    echo
    echo "    postgresql://$ROLE:$PASSWORD@$MY_IP:5432/$DB?sslmode=prefer"
    echo
fi
echo "  Next: copy the three export files here and run import-to-database-vm.sh."
