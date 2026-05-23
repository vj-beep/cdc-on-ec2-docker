#!/usr/bin/env bash
# =============================================================================
# on-demand-merge-env.sh — Merge Existing .env Into Updated .env.template
#
# Walks .env.template line by line, using its structure (comments, sections,
# ordering) as the skeleton for a new .env. Merges your existing .env values
# into the new template and prompts interactively for differences.
#
# For each variable, shows your current value and the template value side by
# side, then either auto-merges or asks what to do.
#
# Usage:
#   ./scripts/on-demand-merge-env.sh                    # Interactive merge
#   ./scripts/on-demand-merge-env.sh --accept-defaults   # Non-interactive: keep existing, accept new defaults
#   ./scripts/on-demand-merge-env.sh --diff-only          # Only show and prompt for differences
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Merge existing .env values into an updated .env.template.
Uses the template as the new structure (comments, sections, ordering) and
carries over your current values. Prompts interactively for differences.

Options:
  --accept-defaults   Non-interactive mode: keep existing values for conflicts,
                      accept template defaults for new variables, keep orphans.
  --diff-only         Only show variables that differ or are new/orphaned.
                      Identical and auto-kept variables are merged silently.
  -h, --help          Show this help message.

Examples:
  $0                    # Interactive merge (shows every variable)
  $0 --diff-only        # Interactive merge (only stops on differences)
  $0 --accept-defaults  # Automated merge (safe for CI)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
ACCEPT_DEFAULTS=false
DIFF_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --accept-defaults) ACCEPT_DEFAULTS=true ;;
        --diff-only) DIFF_ONLY=true ;;
        -h|--help) usage ;;
        *) error "Unknown option: $arg"; echo ""; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
TEMPLATE_FILE="${REPO_ROOT}/.env.template"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    error ".env.template not found: ${TEMPLATE_FILE}"
    exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    error ".env not found: ${ENV_FILE}"
    error "Nothing to merge. Create .env first:  cp .env.template .env"
    exit 1
fi

# ---------------------------------------------------------------------------
# Backup current .env to home directory
# ---------------------------------------------------------------------------
BACKUP="$HOME/.env.backup.$(date +%Y%m%d-%H%M%S)"
cp "${ENV_FILE}" "${BACKUP}"
info "Backed up .env to ${BACKUP}"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
AUTO_MERGED=0
AUTO_KEPT=0
KEPT=0
UPDATED=0
EDITED=0
NEW_ACCEPTED=0
NEW_EDITED=0
ORPHAN_KEPT=0
ORPHAN_DROPPED=0

# ---------------------------------------------------------------------------
# Parse an env value, stripping inline template comments from unquoted values.
# Single-quoted values are returned as-is (they contain special chars).
# ---------------------------------------------------------------------------
parse_value() {
    local raw="$1"
    if [[ "${raw}" =~ ^\'.*\'$ ]]; then
        echo "${raw}"
        return
    fi
    echo "${raw}" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Display a value — dim "(empty)" for blank, bold for real values
# ---------------------------------------------------------------------------
show_val() {
    if [[ -z "$1" ]]; then
        echo -e "${DIM}(empty)${NC}"
    else
        echo -e "${BOLD}$1${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Print a section header from the template (====... lines)
# ---------------------------------------------------------------------------
is_section_header() {
    [[ "$1" =~ ^#\ ====+ ]] || [[ "$1" =~ ^#\ [A-Z][A-Z\ \-\—\:]+$ ]]
}

# ---------------------------------------------------------------------------
# Load current .env into an associative array
# ---------------------------------------------------------------------------
declare -A CURRENT_ENV

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    var_name="${line%%=*}"
    var_name="${var_name// /}"
    [[ -z "${var_name}" ]] && continue
    var_value="${line#*=}"
    CURRENT_ENV["${var_name}"]="${var_value}"
done < "${ENV_FILE}"

# ---------------------------------------------------------------------------
# Count variables in each file
# ---------------------------------------------------------------------------
TEMPLATE_COUNT=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "${TEMPLATE_FILE}" || true)
CURRENT_COUNT="${#CURRENT_ENV[@]}"

echo ""
echo -e "${BOLD}Merging .env into updated .env.template${NC}"
echo -e "${BOLD}================================================${NC}"
echo -e "  Template variables: ${TEMPLATE_COUNT}"
echo -e "  Current .env vars:  ${CURRENT_COUNT}"
echo ""
echo -e "  ${DIM}For each variable: .env (current)  vs  .env.template (new)${NC}"
echo ""

# ---------------------------------------------------------------------------
# Track which template vars we process (to find orphans later)
# ---------------------------------------------------------------------------
declare -A SEEN_VARS

# ---------------------------------------------------------------------------
# Build new .env from template skeleton
# ---------------------------------------------------------------------------
NEW_ENV=$(mktemp)
trap 'rm -f "${NEW_ENV}"' EXIT

LAST_SECTION=""

while IFS= read -r line; do
    # ---- Blank lines and non-section comments: copy verbatim ----
    if [[ -z "${line}" ]]; then
        echo "${line}" >> "${NEW_ENV}"
        continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
        echo "${line}" >> "${NEW_ENV}"
        # Print section headers as visual dividers
        if is_section_header "${line}"; then
            section_text="${line#\# }"
            if [[ "${section_text}" != "${LAST_SECTION}" && ! "${section_text}" =~ ^====+ ]]; then
                echo ""
                echo -e "  ${BOLD}── ${section_text} ──${NC}"
                LAST_SECTION="${section_text}"
            fi
        fi
        continue
    fi

    # ---- Parse variable from template line ----
    var_name="${line%%=*}"
    var_name="${var_name// /}"
    if [[ -z "${var_name}" ]]; then
        echo "${line}" >> "${NEW_ENV}"
        continue
    fi

    raw_value="${line#*=}"
    tmpl_value="$(parse_value "${raw_value}")"
    SEEN_VARS["${var_name}"]=1

    if [[ -v "CURRENT_ENV[${var_name}]" ]]; then
        curr_raw="${CURRENT_ENV[${var_name}]}"
        curr_value="$(parse_value "${curr_raw}")"

        if [[ "${curr_value}" == "${tmpl_value}" ]]; then
            # ---- Identical: auto-merge ----
            echo "${var_name}=${curr_raw}" >> "${NEW_ENV}"
            AUTO_MERGED=$((AUTO_MERGED + 1))
            if [[ "${DIFF_ONLY}" == "false" ]]; then
                echo -e "  ${GREEN}✓${NC} ${var_name}=$(show_val "${curr_value}")"
            fi

        elif [[ -z "${tmpl_value}" && -n "${curr_value}" ]]; then
            # ---- Template is a placeholder, user filled it in ----
            echo "${var_name}=${curr_raw}" >> "${NEW_ENV}"
            AUTO_KEPT=$((AUTO_KEPT + 1))
            if [[ "${DIFF_ONLY}" == "false" ]]; then
                echo -e "  ${GREEN}✓${NC} ${var_name}=$(show_val "${curr_value}")  ${DIM}← your value${NC}"
            fi

        else
            # ---- Values differ ----
            echo ""
            echo -e "  ${YELLOW}≠${NC} ${BOLD}${var_name}${NC}"
            echo -e "    .env:          $(show_val "${curr_value}")"
            echo -e "    .env.template: $(show_val "${tmpl_value}")"

            if [[ "${ACCEPT_DEFAULTS}" == "true" ]]; then
                echo "${var_name}=${curr_raw}" >> "${NEW_ENV}"
                echo -e "    ${DIM}→ accepted current (--accept-defaults)${NC}"
                KEPT=$((KEPT + 1))
            else
                while true; do
                    echo -e "    ${BOLD}A${NC} = accept current (.env)    ${BOLD}O${NC} = override with .env.template    ${BOLD}E${NC} = edit"
                    echo -n -e "    [${BOLD}A${NC}/o/e] "
                    read -r choice </dev/tty
                    case "${choice,,}" in
                        a|"")
                            echo "${var_name}=${curr_raw}" >> "${NEW_ENV}"
                            echo -e "    ${GREEN}→ accepted current${NC}"
                            KEPT=$((KEPT + 1))
                            break ;;
                        o)
                            echo "${var_name}=${tmpl_value}" >> "${NEW_ENV}"
                            echo -e "    ${CYAN}→ overridden with .env.template${NC}"
                            UPDATED=$((UPDATED + 1))
                            break ;;
                        e)
                            echo -n "    Enter value: "
                            read -r new_val </dev/tty
                            echo "${var_name}=${new_val}" >> "${NEW_ENV}"
                            echo -e "    ${CYAN}→ set to: ${new_val}${NC}"
                            EDITED=$((EDITED + 1))
                            break ;;
                        *)
                            echo -e "    ${RED}Invalid choice.${NC}" ;;
                    esac
                done
            fi
            echo ""
        fi
    else
        # ---- New variable: not in current .env ----
        if [[ -z "${tmpl_value}" ]]; then
            # Empty placeholder — nothing to decide, add silently
            echo "${var_name}=${tmpl_value}" >> "${NEW_ENV}"
            NEW_ACCEPTED=$((NEW_ACCEPTED + 1))
            if [[ "${DIFF_ONLY}" == "false" ]]; then
                echo -e "  ${CYAN}+${NC} ${var_name}  ${DIM}(new placeholder, empty)${NC}"
            fi
        else
            echo ""
            echo -e "  ${CYAN}+${NC} ${BOLD}${var_name}${NC}  ${CYAN}(new in .env.template — not in your .env)${NC}"
            echo -e "    .env.template: $(show_val "${tmpl_value}")"

            if [[ "${ACCEPT_DEFAULTS}" == "true" ]]; then
                echo "${var_name}=${tmpl_value}" >> "${NEW_ENV}"
                echo -e "    ${DIM}→ accepted from .env.template (--accept-defaults)${NC}"
                NEW_ACCEPTED=$((NEW_ACCEPTED + 1))
            else
                while true; do
                    echo -e "    ${BOLD}A${NC} = accept from .env.template    ${BOLD}E${NC} = edit"
                    echo -n -e "    [${BOLD}A${NC}/e] "
                    read -r choice </dev/tty
                    case "${choice,,}" in
                        a|"")
                            echo "${var_name}=${tmpl_value}" >> "${NEW_ENV}"
                            echo -e "    ${GREEN}→ accepted from .env.template${NC}"
                            NEW_ACCEPTED=$((NEW_ACCEPTED + 1))
                            break ;;
                        e)
                            echo -n "    Enter value: "
                            read -r new_val </dev/tty
                            echo "${var_name}=${new_val}" >> "${NEW_ENV}"
                            echo -e "    ${CYAN}→ set to: ${new_val}${NC}"
                            NEW_EDITED=$((NEW_EDITED + 1))
                            break ;;
                        *)
                            echo -e "    ${RED}Invalid choice.${NC}" ;;
                    esac
                done
            fi
            echo ""
        fi
    fi
done < "${TEMPLATE_FILE}"

# ---------------------------------------------------------------------------
# Find orphaned variables (in current .env but not in template)
# ---------------------------------------------------------------------------
ORPHAN_NAMES=()
for var_name in "${!CURRENT_ENV[@]}"; do
    if [[ ! -v "SEEN_VARS[${var_name}]" ]]; then
        ORPHAN_NAMES+=("${var_name}")
    fi
done

if [[ ${#ORPHAN_NAMES[@]} -gt 0 ]]; then
    IFS=$'\n' ORPHAN_NAMES=($(sort <<<"${ORPHAN_NAMES[*]}")); unset IFS
fi

if [[ ${#ORPHAN_NAMES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}── REMOVED FROM .env.template ──${NC}"
    echo -e "  ${DIM}These variables are in your .env but no longer in .env.template${NC}"
    echo ""

    ORPHAN_LINES=()
    for var_name in "${ORPHAN_NAMES[@]}"; do
        curr_raw="${CURRENT_ENV[${var_name}]}"
        curr_value="$(parse_value "${curr_raw}")"

        echo -e "  ${RED}−${NC} ${BOLD}${var_name}${NC}=$(show_val "${curr_value}")"

        if [[ "${ACCEPT_DEFAULTS}" == "true" ]]; then
            ORPHAN_LINES+=("${var_name}=${curr_raw}")
            echo -e "    ${DIM}→ kept from .env (--accept-defaults)${NC}"
            ORPHAN_KEPT=$((ORPHAN_KEPT + 1))
        else
            while true; do
                echo -e "    ${BOLD}K${NC} = keep in new .env    ${BOLD}D${NC} = drop"
                echo -n -e "    [${BOLD}K${NC}/d] "
                read -r choice </dev/tty
                case "${choice,,}" in
                    k|"")
                        ORPHAN_LINES+=("${var_name}=${curr_raw}")
                        echo -e "    ${GREEN}→ kept${NC}"
                        ORPHAN_KEPT=$((ORPHAN_KEPT + 1))
                        break ;;
                    d)
                        echo -e "    ${RED}→ dropped${NC}"
                        ORPHAN_DROPPED=$((ORPHAN_DROPPED + 1))
                        break ;;
                    *)
                        echo -e "    ${RED}Invalid choice.${NC}" ;;
                esac
            done
        fi
    done

    if [[ ${#ORPHAN_LINES[@]} -gt 0 ]]; then
        {
            echo ""
            echo "# ============================================================"
            echo "# CUSTOM / LEGACY VARIABLES (not in current .env.template)"
            echo "# Review these after future template upgrades."
            echo "# ============================================================"
            for orphan_line in "${ORPHAN_LINES[@]}"; do
                echo "${orphan_line}"
            done
        } >> "${NEW_ENV}"
    fi
fi

# ---------------------------------------------------------------------------
# Write new .env
# ---------------------------------------------------------------------------
cp "${NEW_ENV}" "${ENV_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "  ${BOLD}Merge complete${NC}"
echo ""
echo -e "  ${GREEN}Unchanged (same in both):${NC}        ${AUTO_MERGED}"
echo -e "  ${GREEN}Carried over from .env:${NC}          ${AUTO_KEPT}"
[[ ${KEPT} -gt 0 ]]           && echo -e "  ${YELLOW}Accepted current (.env):${NC}         ${KEPT}"
[[ ${UPDATED} -gt 0 ]]        && echo -e "  ${CYAN}Overridden with .env.template:${NC}   ${UPDATED}"
[[ ${EDITED} -gt 0 ]]         && echo -e "  ${CYAN}Custom edits:${NC}                    ${EDITED}"
[[ ${NEW_ACCEPTED} -gt 0 ]]   && echo -e "  ${GREEN}New from .env.template:${NC}          ${NEW_ACCEPTED}"
[[ ${NEW_EDITED} -gt 0 ]]     && echo -e "  ${CYAN}New (custom value):${NC}              ${NEW_EDITED}"
[[ ${ORPHAN_KEPT} -gt 0 ]]    && echo -e "  ${YELLOW}Kept (removed from template):${NC}    ${ORPHAN_KEPT}"
[[ ${ORPHAN_DROPPED} -gt 0 ]] && echo -e "  ${RED}Dropped:${NC}                         ${ORPHAN_DROPPED}"
echo ""
echo -e "  Backup: ${BACKUP}"
echo -e "${BOLD}================================================${NC}"

# ---------------------------------------------------------------------------
# Show diff between backup and new .env
# ---------------------------------------------------------------------------
echo ""
if ! diff -q "${BACKUP}" "${ENV_FILE}" >/dev/null 2>&1; then
    echo -e "${BOLD}Diff (backup vs new .env):${NC}"
    echo "--------------------------------------"
    diff --color=always "${BACKUP}" "${ENV_FILE}" || true
    echo "--------------------------------------"
else
    info "No changes — .env is identical to the backup."
fi

echo ""
info "To distribute the updated .env to all nodes:"
echo "  ./scripts/2b-distribute-env.sh"
