#!/usr/bin/env python3
"""
Structural validation for jengasec-infrastructure.

    python3 tests/structure-check.py

Checks the repository is well formed WITHOUT needing Ansible — so it runs on
the Windows machine where this repo is authored, not just on the Debian control
node. That is the point: catching a missing template or an undefined variable
before the files are copied across is much cheaper than finding out mid-run.

What it verifies:
  1. Every YAML file parses
  2. Every Jinja2 template parses
  3. Every {{ variable }} used in a template is defined somewhere
  4. Every template referenced by a task exists
  5. Every include_tasks target exists
  6. Every role named by a playbook exists
  7. Every playbook imported by site.yml exists
  8. Every role has the full skeleton
  9. Every notify resolves to a handler

What it does NOT verify: that a run will succeed. For that you need
`make check` on the control node.

Requires: pyyaml, jinja2
    pip install pyyaml jinja2
"""
import pathlib
import re
import sys

try:
    import yaml
    from jinja2 import Environment, meta
except ImportError:
    sys.exit("Needs pyyaml and jinja2:  pip install pyyaml jinja2")

ROOT = pathlib.Path(__file__).resolve().parent.parent
env = Environment()
problems = []

# Facts and magic variables Ansible always provides. Anything here is treated as
# defined even though it appears in no defaults file.
BUILTIN = {
    "ansible_os_family", "ansible_distribution", "ansible_distribution_version",
    "ansible_distribution_major_version", "ansible_date_time", "ansible_interfaces",
    "ansible_default_ipv4", "ansible_processor_vcpus", "ansible_memtotal_mb",
    "ansible_hostname", "ansible_python_version", "ansible_uptime_seconds",
    "ansible_playbook_python", "inventory_hostname", "inventory_hostname_short",
    "group_names", "groups", "hostvars", "item", "ansible_host", "ansible_port",
    "ansible_user", "play_hosts", "playbook_dir", "role_path", "omit",
}


def head(title):
    print(f"\n== {title} ==")


def bad(msg):
    print(f"  [FAIL] {msg}")
    problems.append(msg)


def rel(path):
    return path.relative_to(ROOT).as_posix()


# ── Gather every defined variable ───────────────────────────────────────────
defined = set(BUILTIN)


def harvest_mapping(path):
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        bad(f"{rel(path)}: {str(exc).splitlines()[0]}")
        return
    if isinstance(data, dict):
        defined.update(data.keys())


for pattern in (
    "roles/*/defaults/main.yml",
    "roles/*/vars/main.yml",
    "inventories/*/group_vars/*/main.yml",
    "inventories/*/host_vars/*.yml",
):
    for path in ROOT.glob(pattern):
        harvest_mapping(path)

example_vault = ROOT / "inventories/production/vault.yml.example"
if example_vault.exists():
    harvest_mapping(example_vault)

# Variables created at run time rather than declared in defaults:
#   set_fact:            os_sysctl_merged, dns_forward_serial, ...
#   task-level vars:     dns_serial, passed to a template task
# Both are legitimate; scrape them so they are not reported as undefined.
RUNTIME_PATTERNS = (
    re.compile(r"set_fact:\s*\n((?:\s+\w+:.*\n)+)"),
    re.compile(r"^\s+vars:\s*\n((?:\s+\w+:.*\n)+)", re.MULTILINE),
)
for tasks in ROOT.rglob("roles/*/tasks/*.yml"):
    text = tasks.read_text(encoding="utf-8")
    for pattern in RUNTIME_PATTERNS:
        for block in pattern.finditer(text):
            for line in block.group(1).splitlines():
                key = line.split(":", 1)[0].strip()
                if key and re.fullmatch(r"\w+", key):
                    defined.add(key)

# ── 1 & 2. Everything parses ────────────────────────────────────────────────
head("YAML")
yaml_count = 0
for path in sorted(ROOT.rglob("*.yml")):
    if any(part in {".venv", "collections", "logs"} for part in path.parts):
        continue
    yaml_count += 1
    try:
        yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        bad(f"{rel(path)}: {str(exc).splitlines()[0]}")
print(f"  {yaml_count} files parsed")

head("Jinja2 templates")
tpl_count = 0
for path in sorted(ROOT.rglob("roles/*/templates/*.j2")):
    tpl_count += 1
    try:
        env.parse(path.read_text(encoding="utf-8"))
    except Exception as exc:
        bad(f"{rel(path)}: {exc}")
print(f"  {tpl_count} templates parsed")

# ── 3. Template variables are defined ───────────────────────────────────────
head("Template variables")
undefined = {}
for path in sorted(ROOT.rglob("roles/*/templates/*.j2")):
    try:
        used = meta.find_undeclared_variables(env.parse(path.read_text(encoding="utf-8")))
    except Exception:
        continue
    for name in sorted(used):
        if name not in defined and not name.startswith("_"):
            undefined.setdefault(name, []).append(rel(path))

for name, files in sorted(undefined.items()):
    bad(f"undefined variable '{name}' used in: {', '.join(files)}")
if not undefined:
    print(f"  OK - every variable resolves ({len(defined)} known)")

# ── 4. Referenced templates exist ───────────────────────────────────────────
head("Template references")
missing = 0
for tasks in sorted(ROOT.rglob("roles/*/tasks/*.yml")):
    role_dir = tasks.parent.parent
    for match in re.finditer(r"src:\s*([A-Za-z0-9_.\-]+\.j2)", tasks.read_text(encoding="utf-8")):
        name = match.group(1)
        if not (role_dir / "templates" / name).exists():
            bad(f"{role_dir.name}: tasks reference templates/{name}, which does not exist")
            missing += 1
if not missing:
    print("  OK - every referenced template exists")

# ── 5. include_tasks targets ────────────────────────────────────────────────
head("include_tasks targets")
for tasks in sorted(ROOT.rglob("roles/*/tasks/*.yml")):
    role_dir = tasks.parent.parent
    text = tasks.read_text(encoding="utf-8")
    for match in re.finditer(r'include_tasks:\s*"?\{\{\s*(\w+)\s*\}\}\.yml"?', text):
        var = match.group(1)
        defaults_file = role_dir / "defaults/main.yml"
        data = yaml.safe_load(defaults_file.read_text(encoding="utf-8")) or {}
        value = data.get(var)
        target = role_dir / "tasks" / f"{value}.yml"
        if value and not target.exists():
            bad(f"{role_dir.name}: include target tasks/{value}.yml does not exist")
        else:
            print(f"  OK - {role_dir.name} includes {{{{ {var} }}}}.yml, default '{value}' resolves")
    for match in re.finditer(r'include_tasks:\s*"?([a-z0-9_\-]+\.yml)"?', text):
        target = role_dir / "tasks" / match.group(1)
        if not target.exists():
            bad(f"{role_dir.name}: include target tasks/{match.group(1)} does not exist")

# ── 6. Playbook role references ─────────────────────────────────────────────
head("Playbook role references")
roles_on_disk = {p.name for p in (ROOT / "roles").iterdir() if p.is_dir()}
missing = 0
playbooks = sorted((ROOT / "playbooks").glob("*.yml")) + [ROOT / "site.yml"]
for playbook in playbooks:
    if not playbook.exists():
        continue
    for match in re.finditer(r"role:\s*([a-z0-9_\-]+)", playbook.read_text(encoding="utf-8")):
        if match.group(1) not in roles_on_disk:
            bad(f"{playbook.name} references role '{match.group(1)}', which does not exist")
            missing += 1
if not missing:
    print(f"  OK - {len(roles_on_disk)} roles on disk, every reference resolves")

# ── 7. site.yml imports ─────────────────────────────────────────────────────
head("site.yml imports")
site = ROOT / "site.yml"
if site.exists():
    for match in re.finditer(r"import_playbook:\s*(\S+)", site.read_text(encoding="utf-8")):
        if (ROOT / match.group(1)).exists():
            print(f"  OK - {match.group(1)}")
        else:
            bad(f"site.yml imports {match.group(1)}, which does not exist")

# ── 8. Role skeletons ───────────────────────────────────────────────────────
head("Role skeletons")
required = ("tasks/main.yml", "defaults/main.yml", "meta/main.yml", "README.md")
incomplete = 0
for role_dir in sorted((ROOT / "roles").iterdir()):
    if not role_dir.is_dir():
        continue
    gaps = [f for f in required if not (role_dir / f).exists()]
    if gaps:
        bad(f"{role_dir.name}: missing {', '.join(gaps)}")
        incomplete += 1
print(f"  {len(roles_on_disk)} roles, {incomplete} incomplete")
if len(roles_on_disk) != 31:
    print(f"  NOTE: expected 31 roles, found {len(roles_on_disk)}")

# ── 9. Handler references ───────────────────────────────────────────────────
head("Handler references")
bad_notify = 0
for role_dir in sorted((ROOT / "roles").iterdir()):
    if not role_dir.is_dir():
        continue
    handlers = set()
    handler_file = role_dir / "handlers/main.yml"
    if handler_file.exists():
        try:
            for handler in yaml.safe_load(handler_file.read_text(encoding="utf-8")) or []:
                if isinstance(handler, dict):
                    handlers.update(str(handler[k]) for k in ("name", "listen") if k in handler)
        except Exception as exc:
            bad(f"{role_dir.name}: handlers/main.yml - {exc}")
    tasks_dir = role_dir / "tasks"
    if not tasks_dir.exists():
        continue
    for tasks in tasks_dir.glob("*.yml"):
        for match in re.finditer(r"notify:\s*(.+)", tasks.read_text(encoding="utf-8")):
            name = match.group(1).strip().strip("\"'")
            if name.startswith(("-", "{")):
                continue
            if name not in handlers:
                bad(f"{role_dir.name}: notify '{name}' has no matching handler")
                bad_notify += 1
if not bad_notify:
    print("  OK - every notify resolves to a handler")

# ── Summary ─────────────────────────────────────────────────────────────────
print("\n" + "=" * 68)
if problems:
    print(f"{len(problems)} problem(s) found:\n")
    for problem in problems:
        print(f"  - {problem}")
    print()
    sys.exit(1)

print("All structural checks passed.")
print()
print("This proves the repository is well formed. It does NOT prove a run will")
print("succeed - for that, on the Debian control node:")
print("    make lint && make syntax && make check")
print()
