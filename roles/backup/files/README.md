# Backup encryption key

The **public** half of the GPG key backups are encrypted to. The role copies it
to the backup host and imports it.

```
jengasec-backup.pub.asc
```

## Generating it

**Not on server3.** The whole point is that the backup host cannot read what it
stores — someone who compromises it should get encrypted archives and nothing
else.

On a laptop, or any machine that is not part of this infrastructure:

```bash
gpg --full-generate-key
#   RSA and RSA, 4096 bits, no expiry
#   Name:  JengaSec Backups
#   Email: backups@jengasec.example

gpg --armor --export backups@jengasec.example > jengasec-backup.pub.asc
```

Put that file here and set `backup_gpg_recipient` in
`group_vars/backup/main.yml` to the email address.

## The private key

**Keep it off every server in this repository**, and make sure **more than one
person can reach it**.

That second part is the one clubs get wrong. A backup only one graduating
student can decrypt is a backup the club loses access to. Put the private key
and its passphrase in the club's password manager, or split it between two
officers.

The natural place to store it is precisely the environment you would be
recovering from — so store it somewhere else.

```bash
gpg --armor --export-secret-keys backups@jengasec.example > private-KEEP-SAFE.asc
```

Never commit that file. `.gitignore` excludes `*.asc` in this directory apart
from the public key, but the real protection is not putting it here at all.

## Verifying a restore

`jengasec-backup-verify` needs the private key, which by design is not on the
backup host. So the monthly timer fails at the decryption step until you either
import the key temporarily or run the script from the machine that holds it.

That tension is deliberate and worth deciding consciously: automated
verification and key separation pull against each other. Running the
verification by hand once a month from a laptop that holds the key is a
reasonable answer, and better than leaving the private key on server3.
