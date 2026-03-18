#!/usr/bin/env bash
#===============================================================================
#  bump-version.sh - Controle de versão unificado
#  Atualiza versões em todos os componentes do DevOps Permissions Manager
#
#  Uso:
#    ./bump-version.sh patch    # 5.1.0 -> 5.1.1 (bugfix)
#    ./bump-version.sh minor    # 5.1.0 -> 5.2.0 (nova feature)
#    ./bump-version.sh major    # 5.1.0 -> 6.0.0 (breaking change)
#    ./bump-version.sh show     # mostra versões atuais
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arquivos e seus padrões de versão
MANAGER_SH="$SCRIPT_DIR/devs_permissions_manager.sh"
AUTO_INSTALL_SH="$SCRIPT_DIR/auto-install.sh"
HELPER_SH="$SCRIPT_DIR/devs-permissions-cockpit/bridge/cockpit-helper.sh"
PLUGIN_JS="$SCRIPT_DIR/devs-permissions-cockpit/src/devs-permissions.js"
MANIFEST_JSON="$SCRIPT_DIR/devs-permissions-cockpit/src/manifest.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

#===============================================================================
# Funções de versão
#===============================================================================

get_version() {
    local file="$1" pattern="$2"
    grep -oP "$pattern" "$file" 2>/dev/null | head -1
}

bump_semver() {
    local version="$1" type="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"

    case "$type" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *) echo "$version" ;;
    esac
}

update_file() {
    local file="$1" old="$2" new="$3" label="$4"

    if [[ ! -f "$file" ]]; then
        echo -e "  ${RED}SKIP${NC} $label - arquivo não encontrado: $file"
        return 1
    fi

    if grep -qF "$old" "$file"; then
        sed -i "s|$old|$new|g" "$file"
        echo -e "  ${GREEN}OK${NC}   $label: $old -> ${BOLD}$new${NC}"
        return 0
    else
        echo -e "  ${YELLOW}WARN${NC} $label: padrão '$old' não encontrado em $file"
        return 1
    fi
}

#===============================================================================
# Leitura de versões atuais
#===============================================================================

get_current_versions() {
    MANAGER_VER=$(get_version "$MANAGER_SH" '(?<=SCRIPT_VERSION=")[0-9]+\.[0-9]+\.[0-9]+')
    INSTALLER_VER=$(get_version "$AUTO_INSTALL_SH" '(?<=SCRIPT_VERSION=")[0-9]+\.[0-9]+\.[0-9]+')
    HELPER_VER=$(get_version "$HELPER_SH" '(?<=HELPER_VERSION=")[0-9]+\.[0-9]+\.[0-9]+')
    PLUGIN_VER=$(get_version "$PLUGIN_JS" '(?<=Versao: )[0-9]+\.[0-9]+\.[0-9]+')
    MANIFEST_VER=$(get_version "$MANIFEST_JSON" '(?<="version": ")[0-9]+\.[0-9]+\.[0-9]+')
}

show_versions() {
    get_current_versions

    echo -e "\n${BOLD}=== Versões Atuais ===${NC}\n"
    echo -e "  ${BLUE}Manager${NC}      (devs_permissions_manager.sh):  ${BOLD}v${MANAGER_VER:-?}${NC}"
    echo -e "  ${BLUE}Installer${NC}    (auto-install.sh):              ${BOLD}v${INSTALLER_VER:-?}${NC}"
    echo -e "  ${BLUE}Helper${NC}       (cockpit-helper.sh):            ${BOLD}v${HELPER_VER:-?}${NC}"
    echo -e "  ${BLUE}Plugin JS${NC}    (devs-permissions.js):          ${BOLD}v${PLUGIN_VER:-?}${NC}"
    echo -e "  ${BLUE}Manifest${NC}     (manifest.json):                ${BOLD}v${MANIFEST_VER:-?}${NC}"
    echo ""
}

#===============================================================================
# Bump
#===============================================================================

do_bump() {
    local bump_type="$1"

    get_current_versions

    local new_manager new_installer new_helper new_plugin new_manifest
    new_manager=$(bump_semver "$MANAGER_VER" "$bump_type")
    new_installer=$(bump_semver "$INSTALLER_VER" "$bump_type")
    new_helper=$(bump_semver "$HELPER_VER" "$bump_type")
    new_plugin=$(bump_semver "$PLUGIN_VER" "$bump_type")
    new_manifest=$(bump_semver "$MANIFEST_VER" "$bump_type")

    echo -e "\n${BOLD}=== Version Bump: ${bump_type} ===${NC}\n"

    # Manager script
    update_file "$MANAGER_SH" \
        "SCRIPT_VERSION=\"${MANAGER_VER}\"" \
        "SCRIPT_VERSION=\"${new_manager}\"" \
        "Manager SCRIPT_VERSION"

    update_file "$MANAGER_SH" \
        "VERSÃO: ${MANAGER_VER}" \
        "VERSÃO: ${new_manager}" \
        "Manager header"

    # Auto-install
    update_file "$AUTO_INSTALL_SH" \
        "SCRIPT_VERSION=\"${INSTALLER_VER}\"" \
        "SCRIPT_VERSION=\"${new_installer}\"" \
        "Installer SCRIPT_VERSION"

    # Helper
    update_file "$HELPER_SH" \
        "HELPER_VERSION=\"${HELPER_VER}\"" \
        "HELPER_VERSION=\"${new_helper}\"" \
        "Helper HELPER_VERSION"

    # Plugin JS
    update_file "$PLUGIN_JS" \
        "Versao: ${PLUGIN_VER}" \
        "Versao: ${new_plugin}" \
        "Plugin JS header"

    # Manifest
    update_file "$MANIFEST_JSON" \
        "\"version\": \"${MANIFEST_VER}\"" \
        "\"version\": \"${new_manifest}\"" \
        "Manifest version"

    # Atualiza data no header do manager
    local today
    today=$(date +%Y-%m-%d)
    if grep -q "ATUALIZADO:" "$MANAGER_SH"; then
        sed -i "s|ATUALIZADO:.*|ATUALIZADO: ${today}|" "$MANAGER_SH"
        echo -e "  ${GREEN}OK${NC}   Manager ATUALIZADO: ${today}"
    fi

    echo -e "\n${GREEN}${BOLD}Versões atualizadas com sucesso!${NC}\n"

    show_versions

    echo -e "${YELLOW}Próximos passos:${NC}"
    echo -e "  git add -A && git commit -m 'chore: bump versions (${bump_type})'"
    echo -e "  # depois faça deploy com o auto-install.sh\n"
}

#===============================================================================
# Main
#===============================================================================

case "${1:-show}" in
    patch|minor|major)
        do_bump "$1"
        ;;
    show|status)
        show_versions
        ;;
    -h|--help|help)
        echo -e "\n${BOLD}bump-version.sh${NC} - Controle de versão unificado\n"
        echo "Uso:"
        echo "  ./bump-version.sh patch    Bugfix (5.1.0 -> 5.1.1)"
        echo "  ./bump-version.sh minor    Feature (5.1.0 -> 5.2.0)"
        echo "  ./bump-version.sh major    Breaking (5.1.0 -> 6.0.0)"
        echo "  ./bump-version.sh show     Mostra versões atuais"
        echo ""
        ;;
    *)
        echo -e "${RED}Opção inválida: $1${NC}"
        echo "Use: ./bump-version.sh {patch|minor|major|show}"
        exit 1
        ;;
esac
