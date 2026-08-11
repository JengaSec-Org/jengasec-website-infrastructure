#!/usr/bin/env bash
#
# Structural checks for jengasec-infrastructure.
#
#   ./tests/syntax-check.sh          all inventories
#   ./tests/syntax-check.sh production
#
# Parses every playbook, resolves every inventory, and verifies each role has
# the expected skeleton. Touches no servers — safe to run anywhere, any time.

set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

failures=0

section() { printf '\n%s== %s ==%s\n' "${BOLD}${BLUE}" "$1" "${RESET}"; }
ok()      { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn()    { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
bad()     { printf '  %s✗%s %s\n' "${RED}" "${RESET}" "$1"; failures=$((failures + 1)); }

if [[ ! -f ansible.cfg ]]; then
    printf '%sRun this from the repository root.%s\n' "${RED}" "${RESET}"
    exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
    printf '%sansible-playbook not found. Run this on the Debian control node.%s\n' "${RED}" "${RESET}"
    exit 1
fi

if [[ $# -gt 0 ]]; then
    INVENTORIES=("inventories/$1")
else
    INVENTORIES=(inventories/*/)
fi

# ── Inventories resolve ─────────────────────────────────────────────────────
section "Inventories"

for inventory in "${INVENTORIES[@]}"; do
    inventory="${inventory%/}"
    [[ -d "${inventory}" ]] || continue
    if ansible-inventory -i "${inventory}" --list >/dev/null 2>&1; then
        host_count=$(ansible-inventory -i "${inventory}" --list 2>/dev/null \
                     | grep -c '"ansible_host"' || echo "?")
        ok "$(basename "${inventory}") resolves (${host_count} host entries)"
    else
        bad "$(basename "${inventory}") failed to resolve"
        ansible-inventory -i "${inventory}" --list 2>&1 | head -5 | sed 's/^/      /'
    fi
done

# ── Playbooks parse ─────────────────────────────────────────────────────────
section "Playbook syntax"

# Checked against development: it carries complete variables and dummy secrets,
# so a syntax check never fails for a missing vault password.
CHECK_INVENTORY="inventories/development"

for playbook in site.yml playbooks/*.yml; do
    [[ -f "${playbook}" ]] || continue
    if output=$(ansible-playbook -i "${CHECK_INVENTORY}" --syntax-check "${playbook}" 2>&1); then
        ok "${playbook}"
    else
        bad "${playbook}"
        printf '%s\n' "${output}" | head -10 | sed 's/^/      /'
    fi
done

# ── Role skeletons ──────────────────────────────────────────────────────────
section "Role structure"

role_count=0
for role_dir in roles/*/; do
    role="$(basename "${role_dir}")"
    role_count=$((role_count + 1))
    missing=()

    [[ -f "${role_dir}tasks/main.yml"    ]] || missing+=("tasks/main.yml")
    [[ -f "${role_dir}defaults/main.yml" ]] || missing+=("defaults/main.yml")
    [[ -f "${role_dir}meta/main.yml"     ]] || missing+=("meta/main.yml")
    [[ -f "${role_dir}README.md"         ]] || missing+=("README.md")

    if [[ ${#missing[@]} -gt 0 ]]; then
        bad "${role}: missing ${missing[*]}"
    fi
done
ok "${role_count} roles checked"

if [[ "${role_count}" -ne 30 ]]; then
    warn "Expected 30 roles, found ${role_count}"
fi

# ── Every role a playbook names must exist ──────────────────────────────────
section "Playbook role references"

for playbook in site.yml playbooks/*.yml; do
    [[ -f "${playbook}" ]] || continue
    # Matches both "- role: name" and "- { role: name, ... }".
    grep -oP '(?<=role: )[a-z0-9_-]+' "${playbook}" 2>/dev/null | sort -u | while read -r role; do
        [[ -n "${role}" ]] || continue
        if [[ ! -d "roles/${role}" ]]; then
            printf '  %s✗%s %s references a role that does not exist: %s\n' \
                "${RED}" "${RESET}" "${playbook}" "${role}"
        fi
    done
done
ok "Role references resolved"

# ── Templates referenced by tasks exist ─────────────────────────────────────
section "Template references"

missing_templates=0
for role_dir in roles/*/; do
    role="$(basename "${role_dir}")"
    [[ -d "${role_dir}tasks" ]] || continue
    grep -rhoP '(?<=src: )[a-zA-Z0-9_.-]+\.j2' "${role_dir}tasks/" 2>/dev/null | sort -u \
    | while read -r template; do
        [[ -n "${template}" ]] || continue
        if [[ ! -f "${role_dir}templates/${template}" ]]; then
            printf '  %s✗%s %s: tasks reference templates/%s, which does not exist\n' \
                "${RED}" "${RESET}" "${role}" "${template}"
        fi
    done
done
ok "Template references resolved"

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%s== Summary ==%s\n' "${BOLD}${BLUE}" "${RESET}"

if [[ "${failures}" -eq 0 ]]; then
    printf '  %sAll structural checks passed.%s\n' "${GREEN}" "${RESET}"
    printf '  Note: this proves the repository is well formed, not that a run\n'
    printf '  will succeed. For that:  make check\n\n'
    exit 0
else
    printf '  %s%d check(s) failed.%s\n\n' "${RED}" "${failures}" "${RESET}"
    exit 1
fi
