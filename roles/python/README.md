# `python`

**Phase 1 · Implemented**

The Python runtime the platform and several roles depend on.

## Version: 3.11, not 3.12

Debian 12 ships Python 3.11. The platform's README asks for 3.12+, but that is a
preference rather than a requirement — Django 5.0 and 5.1 both support 3.11, and
every package in `requirements.txt` (psycopg2-binary, PyMuPDF, pdfplumber,
reportlab, pandas, gunicorn, whitenoise) has a 3.11 wheel.

So this role uses the system interpreter. Building Python from source means
owning its security updates by hand forever, and Debian will not patch it for
you. That is a poor trade for a version number.

If a dependency ever genuinely requires 3.12, it is one variable:

```yaml
python_build_from_source: true
python_source_version: "3.12.7"
```

The build tasks are written and tested-by-inspection but disabled. They use
`make altinstall`, never `make install` — a plain install can shadow the system
interpreter, and apt is written in Python, so recovering from that on a remote
server is genuinely unpleasant.

See [docs/decisions.md](../../docs/decisions.md).

## PEP 668

Debian 12 marks the system Python as externally managed, so `pip install`
outside a virtualenv is refused. **This role does not work around that.**

It is correct behaviour. Application dependencies belong in the virtualenv the
`django` role creates. Mixing pip and apt packages in `/usr/lib/python3` gives
you a machine where apt and pip each believe they own a different version of the
same library, and the failure shows up weeks later during an unrelated upgrade.

`python_pip_break_system_packages` exists as an escape hatch. Do not use it.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `python_packages` | python3, pip, venv, dev, setuptools, wheel, apt | `python3-dev` is required for psycopg2 and PyMuPDF |
| `python_interpreter` | `/usr/bin/python3` | Referenced by other roles |
| `python_build_from_source` | `false` | See above |
| `python_source_version` | `3.12.7` | Only used when the above is true |
| `python_manage_pip_conf` | `true` | Writes `/etc/pip.conf` |
| `python_pip_index_url` | PyPI | Point at a local mirror if you have one |

## Tags

`python`, `packages`, `pip`, `verify`, `source-build`

## Verifying

```bash
python3 --version
python3 -m venv --help
python3 -c "import sysconfig; print(sysconfig.get_paths()['include'])"
cat /etc/pip.conf
```

The third command must print a path that exists — if the headers are missing,
`pip install psycopg2` fails with an error about `Python.h` that does not
mention Python headers at all.
