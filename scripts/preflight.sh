#!/usr/bin/env bash
#
# Preflight checks for jengasec-infrastructure.
#
#   ./scripts/preflight.sh [inventory]
#
# Run this before the first deployment and any time something behaves oddly.
# It checks the control node, the repository, and whether the hosts answer —
# all the things that produce a confusing Ansible error if they are wrong.
#
# Exits non-zero if anything would block a run.

set -uo pipefail

INVENTORY="${1:-inventories/production}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

errors=0
warnings=0

section() { printf '\n%s== %s ==%s\n' "${BOLD}${BLUE}" "$1" "${RESET}"; }
ok()      { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$1"; }
warn()    { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$1"; warnings=$((warnings + 1)); }
fail()    { printf '  %s✗%s %s\n' "${RED}" "${RESET}" "$1"; errors=$((errors + 1)); }

printf '%sJengaSec Infrastructure — preflight%s\n' "${BOLD}" "${RESET}"
printf 'Inventory: %s\n' "${INVENTORY}"

# ── Control node ────────────────────────────────────────────────────────────
section "Control node"

if [[ "$(uname -s)" == "Linux" ]]; then
    ok "Running on Linux ($(uname -r))"
else
    fail "Not Linux. Ansible has no supported Windows control node — run from the Debian machine."
fi

if command -v ansible >/dev/null 2>&1; then
    ok "ansible: $(ansible --version | head -1)"
else
    fail "ansible not found.  sudo apt install ansible-core"
fi

for tool in ansible-playbook ansible-inventory ansible-vault ssh; do
    if command -v "${tool}" >/dev/null 2>&1; then
        ok "${tool} present"
    else
        fail "${tool} not found"
    fi
done

for tool in yamllint ansible-lint; do
    if command -v "${tool}" >/dev/null 2>&1; then
        ok "${tool} present"
    else
        warn "${tool} not found — 'make lint' will not work.  sudo apt install ${tool}"
    fi
done

# ── Collections ─────────────────────────────────────────────────────────────
section "Galaxy collections"

for collection in ansible.posix community.general community.crypto; do
    if ansible-galaxy collection list 2>/dev/null | grep -q "^${collection} "; then
        ok "${collection}"
    else
        fail "${collection} missing.  ansible-galaxy collection install -r requirements.yml"
    fi
done

# ── Repository ──────────────────────────────────────────────────────────────
section "Repository"

if [[ -f ansible.cfg ]]; then
    ok "ansible.cfg found — running from the repository root"
else
    fail "ansible.cfg not found. Run this from the repository root."
fi

if [[ -d "${INVENTORY}" ]]; then
    ok "Inventory ${INVENTORY} exists"
else
    fail "Inventory ${INVENTORY} not found"
fi

# CRLF line endings survive a copy from Windows and break shell scripts with
# "bad interpreter: /bin/bash^M" — an error that names the wrong problem.
if command -v file >/dev/null 2>&1; then
    crlf_count=$(find . -name '*.sh' -exec file {} \; 2>/dev/null | grep -c CRLF || true)
    if [[ "${crlf_count}" -gt 0 ]]; then
        fail "${crlf_count} shell script(s) have CRLF line endings. Fix:  find . -name '*.sh' -exec dos2unix {} +"
    else
        ok "No CRLF line endings in shell scripts"
    fi
fi

# ── Unreplaced placeholders ─────────────────────────────────────────────────
section "Inventory placeholders"

todo_count=$(grep -rn "TODO: replace" "${INVENTORY}" 2>/dev/null | wc -l || echo 0)
if [[ "${todo_count}" -gt 0 ]]; then
    warn "${todo_count} unreplaced placeholder(s) in ${INVENTORY}:"
    grep -rn "TODO: replace" "${INVENTORY}" 2>/dev/null | sed 's/^/      /' | head -25
    if [[ "${todo_count}" -gt 25 ]]; then
        printf '      ... and %d more\n' "$((todo_count - 25))"
    fi
else
    ok "No unreplaced placeholders"
fi

# ── Secrets ─────────────────────────────────────────────────────────────────
section "Secrets"

if [[ -f "${INVENTORY}/vault.yml" ]]; then
    if head -1 "${INVENTORY}/vault.yml" | grep -q '^\$ANSIBLE_VAULT'; then
        ok "vault.yml exists and is encrypted"
    else
        fail "vault.yml is NOT ENCRYPTED. Run: ansible-vault encrypt ${INVENTORY}/vault.yml"
    fi
else
    warn "No vault.yml. Copy the example:  cp ${INVENTORY}/vault.yml.example ${INVENTORY}/vault.yml"
fi

if [[ -f .vault_pass ]]; then
    perms=$(stat -c '%a' .vault_pass 2>/dev/null || echo "?")
    if [[ "${perms}" == "600" || "${perms}" == "400" ]]; then
        ok ".vault_pass permissions are ${perms}"
    else
        fail ".vault_pass is mode ${perms} — other local accounts can read it.  chmod 600 .vault_pass"
    fi
fi

key_count=$(find roles/users/files/ssh-keys -name '*.pub' 2>/dev/null | wc -l || echo 0)
if [[ "${key_count}" -gt 0 ]]; then
    ok "${key_count} SSH public key(s) present"
    # A private key here would be committed and would have to be treated as
    # compromised, so it is worth one grep.
    if grep -rl 'PRIVATE KEY' roles/users/files/ssh-keys/ 2>/dev/null | grep -q .; then
        fail "A PRIVATE KEY is in roles/users/files/ssh-keys/. Remove it and rotate that key."
    fi
else
    warn "No SSH public keys in roles/users/files/ssh-keys/ — the users role will refuse to run"
fi

# ── Syntax ──────────────────────────────────────────────────────────────────
section "Playbook syntax"

if command -v ansible-playbook >/dev/null 2>&1; then
    for playbook in site.yml playbooks/*.yml; do
        [[ -f "${playbook}" ]] || continue
        if ansible-playbook -i "${INVENTORY}" --syntax-check "${playbook}" >/dev/null 2>&1; then
            ok "$(basename "${playbook}")"
        else
            fail "$(basename "${playbook}") — run: ansible-playbook -i ${INVENTORY} --syntax-check ${playbook}"
        fi
    done
fi

# ── Host reachability ───────────────────────────────────────────────────────
section "Host reachability"

if command -v ansible >/dev/null 2>&1 && [[ -d "${INVENTORY}" ]]; then
    hosts=$(ansible-inventory -i "${INVENTORY}" --list 2>/dev/null \
            | grep -oP '"\K[a-z0-9_-]+(?=": \{$)' | sort -u || true)
    if [[ -z "${hosts}" ]]; then
        warn "Could not enumerate hosts from the inventory"
    else
        while read -r host; do
            [[ -n "${host}" ]] || continue
            if ansible -i "${INVENTORY}" "${host}" -m ansible.builtin.ping >/dev/null 2>&1; then
                ok "${host} reachable"
            else
                warn "${host} unreachable — expected if it is not built yet"
            fi
        done <<< "${hosts}"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%s== Summary ==%s\n' "${BOLD}${BLUE}" "${RESET}"

if [[ "${errors}" -eq 0 && "${warnings}" -eq 0 ]]; then
    printf '  %sReady.%s\n\n' "${GREEN}" "${RESET}"
    exit 0
elif [[ "${errors}" -eq 0 ]]; then
    printf '  %s%d warning(s)%s — safe to proceed, but read them.\n\n' "${YELLOW}" "${warnings}" "${RESET}"
    exit 0
else
    printf '  %s%d error(s)%s and %d warning(s). Fix the errors first.\n\n' \
        "${RED}" "${errors}" "${RESET}" "${warnings}"
    exit 1
fi
