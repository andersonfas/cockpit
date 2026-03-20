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
#
#  Nota: manifest.json NÃO é bumped - seu campo "version" é a API version
#        do Cockpit (inteiro), não a versão do plugin.
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Componentes e seus arquivos
MANAGER_SH="$SCRIPT_DIR/devs_permissions_manager.sh"
AUTO_INSTALL_SH="$SCRIPT_DIR/auto-install.sh"
HELPER_SH="$SCRIPT_DIR/devs-permissions-cockpit/bridge/cockpit-helper.sh"
PLUGIN_JS="$SCRIPT_DIR/devs-permissions-cockpit/src/devs-permissions.js"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0

#===============================================================================
# Funções de versão
#===============================================================================

get_version() {
    local file="$1" pattern="$2"
    if [[ ! -f "$file" ]]; then
        echo ""
        return
    fi
    grep -oP "$pattern" "$file" 2>/dev/null | head -1 || echo ""
}

validate_semver() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "  ${RED}ERROR${NC} Versão inválida: '$version' (esperado: X.Y.Z)" >&2
        return 1
    fi
}

bump_semver() {
    local version="$1" type="$2"
    local major minor patch

    if ! validate_semver "$version"; then
        return 1
    fi

    local old_ifs="$IFS"
    IFS='.' read -r major minor patch <<< "$version"
    IFS="$old_ifs"

    case "$type" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
    esac
}

update_file() {
    local file="$1" old="$2" new="$3" label="$4"

    if [[ ! -f "$file" ]]; then
        echo -e "  ${RED}SKIP${NC} $label - arquivo não encontrado: $file"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    if ! grep -qF "$old" "$file"; then
        echo -e "  ${YELLOW}WARN${NC} $label: padrão '$old' não encontrado"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    # Cria backup antes de editar
    cp "$file" "${file}.bak"

    if sed -i "s|${old}|${new}|g" "$file"; then
        # Verifica se a substituição realmente aconteceu
        if grep -qF "$new" "$file"; then
            rm -f "${file}.bak"
            echo -e "  ${GREEN}OK${NC}   $label: $old -> ${BOLD}$new${NC}"
            return 0
        else
            # Restaura backup se sed não fez a substituição
            mv "${file}.bak" "$file"
            echo -e "  ${RED}FAIL${NC} $label: substituição não efetivada"
            ERRORS=$((ERRORS + 1))
            return 1
        fi
    else
        mv "${file}.bak" "$file"
        echo -e "  ${RED}FAIL${NC} $label: erro no sed"
        ERRORS=$((ERRORS + 1))
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
}

show_versions() {
    get_current_versions

    echo -e "\n${BOLD}=== Versões Atuais ===${NC}\n"
    echo -e "  ${BLUE}Manager${NC}      (devs_permissions_manager.sh):  ${BOLD}v${MANAGER_VER:-?}${NC}"
    echo -e "  ${BLUE}Installer${NC}    (auto-install.sh):              ${BOLD}v${INSTALLER_VER:-?}${NC}"
    echo -e "  ${BLUE}Helper${NC}       (cockpit-helper.sh):            ${BOLD}v${HELPER_VER:-?}${NC}"
    echo -e "  ${BLUE}Plugin JS${NC}    (devs-permissions.js):          ${BOLD}v${PLUGIN_VER:-?}${NC}"
    echo ""
}

#===============================================================================
# Bump
#===============================================================================

do_bump() {
    local bump_type="$1"
    ERRORS=0

    get_current_versions

    # Valida que conseguiu ler todas as versões
    local missing=false
    for var in MANAGER_VER INSTALLER_VER HELPER_VER PLUGIN_VER; do
        if [[ -z "${!var}" ]]; then
            echo -e "${RED}ERROR${NC} Não foi possível ler versão: $var"
            missing=true
        fi
    done
    if [[ "$missing" == true ]]; then
        echo -e "\n${RED}Abortando bump. Corrija os erros acima.${NC}"
        exit 1
    fi

    local new_manager new_installer new_helper new_plugin
    new_manager=$(bump_semver "$MANAGER_VER" "$bump_type") || exit 1
    new_installer=$(bump_semver "$INSTALLER_VER" "$bump_type") || exit 1
    new_helper=$(bump_semver "$HELPER_VER" "$bump_type") || exit 1
    new_plugin=$(bump_semver "$PLUGIN_VER" "$bump_type") || exit 1

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

    # Atualiza data no header do manager
    local today
    today=$(date +%Y-%m-%d)
    if grep -q "ATUALIZADO:" "$MANAGER_SH"; then
        cp "$MANAGER_SH" "${MANAGER_SH}.bak"
        sed -i "s|ATUALIZADO:.*|ATUALIZADO: ${today}|" "$MANAGER_SH"
        rm -f "${MANAGER_SH}.bak"
        echo -e "  ${GREEN}OK${NC}   Manager ATUALIZADO: ${today}"
    fi

    if [[ $ERRORS -gt 0 ]]; then
        echo -e "\n${YELLOW}Concluído com ${ERRORS} aviso(s).${NC}"
    else
        echo -e "\n${GREEN}${BOLD}Versões atualizadas com sucesso!${NC}"
    fi

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
        echo "Componentes atualizados:"
        echo "  - devs_permissions_manager.sh (SCRIPT_VERSION + header)"
        echo "  - auto-install.sh (SCRIPT_VERSION)"
        echo "  - cockpit-helper.sh (HELPER_VERSION)"
        echo "  - devs-permissions.js (Versao header)"
        echo ""
        echo "Nota: manifest.json NÃO é alterado (campo 'version' é API version do Cockpit)"
        echo ""
        ;;
    *)
        echo -e "${RED}Opção inválida: $1${NC}"
        echo "Use: ./bump-version.sh {patch|minor|major|show}"
        exit 1
        ;;
esac
