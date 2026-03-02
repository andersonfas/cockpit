#!/usr/bin/env bash
#===============================================================================
#
#   INSTALADOR UNIVERSAL - devs-permissions-cockpit
#
#   Detecta a distro e instala o plugin usando o método mais adequado.
#   Funciona em RHEL/CentOS/Rocky 8+, Ubuntu 20.04+, Debian 11+.
#
#   USO:
#       sudo ./install.sh                    # Instala
#       sudo ./install.sh --uninstall        # Remove
#       sudo ./install.sh --with-scripts     # Instala plugin + copia scripts
#       sudo ./install.sh --build-rpm        # Apenas gera o RPM sem instalar
#
#===============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NAME="devs-permissions-cockpit"
readonly VERSION="1.0.0"

# Paths FHS
readonly COCKPIT_DIR="/usr/share/cockpit/devs-permissions"
readonly LIBEXEC_DIR="/usr/libexec/devs-permissions"
readonly CONFIG_DIR="/etc/devs-permissions"
readonly DATA_DIR="/var/lib/devs_permissions"
readonly LOG_DIR="/var/log/devs_audit"
readonly BACKUP_DIR="/var/backups/devs_permissions"

# Cores
if [[ -t 1 ]]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' N='\033[0m'
else
    R='' G='' Y='' B='' N=''
fi

info()  { echo -e "${G}[INFO]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*"; }
error() { echo -e "${R}[ERRO]${N} $*" >&2; }
header(){ echo -e "\n${B}=== $* ===${N}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Execute como root: sudo $0 $*"
        exit 1
    fi
}

check_cockpit() {
    if ! command -v cockpit-bridge &>/dev/null || [[ ! -d "/usr/share/cockpit" ]]; then
        error "Cockpit nao encontrado."
        echo ""
        echo "Instale primeiro:"
        echo "  RHEL/CentOS/Rocky: sudo dnf install cockpit && sudo systemctl enable --now cockpit.socket"
        echo "  Ubuntu/Debian:     sudo apt install cockpit && sudo systemctl enable --now cockpit.socket"
        exit 1
    fi
}

check_files() {
    local required=(
        "src/manifest.json"
        "src/index.html"
        "src/devs-permissions.js"
        "src/devs-permissions.css"
        "bridge/cockpit-helper.sh"
    )
    for f in "${required[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
            error "Arquivo obrigatorio nao encontrado: ${f}"
            exit 1
        fi
    done
}

cleanup_old_installs() {
    # Remove instalações anteriores com nomes diferentes para evitar menus duplicados
    local old_dirs=(
        "/usr/share/cockpit/devs-permissions-cockpit"
        "/usr/share/cockpit/devs_permissions"
    )
    for dir in "${old_dirs[@]}"; do
        if [[ -d "$dir" && "$dir" != "$COCKPIT_DIR" ]]; then
            warn "Removendo instalacao antiga em ${dir}..."
            rm -rf "$dir"
        fi
    done
}

ensure_config() {
    # Cria config base se não existir
    if [[ ! -f "${CONFIG_DIR}/devs_permissions.conf" ]]; then
        info "Criando configuracao base em ${CONFIG_DIR}/devs_permissions.conf..."
        cat > "${CONFIG_DIR}/devs_permissions.conf" <<'CONF'
#===============================================================================
# DevOps Permissions Manager - Configuracao
# Gerado automaticamente pelo instalador
#===============================================================================

# Ambiente: development, staging, production
ENVIRONMENT="production"

# Grupos do sistema
GRUPO_DEV="devs"
GRUPO_DEV_EXEC="devs_exec"
GRUPO_DEV_WEBCONF="devs_webconf"

# Comportamento automatico
AUTO_CREATE_USERS=true
AUTO_CREATE_GROUPS=true
DEFAULT_SHELL="/bin/bash"

# Docker socket
DOCKER_SOCKET="/var/run/docker.sock"

# Auditoria
ENABLE_AUDIT="true"
AUDIT_LOG_DIR="/var/log/devs_audit"

# Controle por ambiente
PROD_REQUIRES_APPROVAL=true
PROD_MAX_TEMP_HOURS=4
STAGING_MAX_TEMP_HOURS=8
DEV_MAX_TEMP_HOURS=24
MAX_TEMP_HOURS=8

# Inatividade
INACTIVITY_DAYS=30
AUTO_REVOKE_INACTIVE=false

# Notificacoes (configure o webhook do seu Slack/Teams/Discord)
WEBHOOK_URL=""
WEBHOOK_TYPE="slack"
NOTIFY_ON_EXEC=false
NOTIFY_ON_TEMP_ACCESS=true
NOTIFY_ON_REQUEST=true
NOTIFY_ON_SUSPICIOUS=true
REPORT_EMAIL=""

# Times (exemplo - edite conforme necessario)
TEAMS=(
    "exemplo"
)
TEAM_exemplo_USERS=(
    "usuario1"
)
TEAM_exemplo_CONTAINERS=(
    "container1"
)
CONF
        chmod 644 "${CONFIG_DIR}/devs_permissions.conf"
    fi
}

do_install() {
    header "Instalando ${NAME} v${VERSION}"

    check_cockpit
    check_files

    # Limpar instalações anteriores com nomes diferentes
    cleanup_old_installs

    # Criar diretórios (dados sensíveis com permissões restritivas)
    info "Criando diretorios..."
    mkdir -p "$COCKPIT_DIR"
    mkdir -p "$LIBEXEC_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p -m 750 "${DATA_DIR}/temp_access"
    mkdir -p -m 750 "${DATA_DIR}/requests"
    mkdir -p -m 750 "${LOG_DIR}/sessions"
    mkdir -p -m 750 "$BACKUP_DIR"

    # Instalar plugin Cockpit
    info "Instalando plugin Cockpit..."
    install -m 644 "${SCRIPT_DIR}/src/manifest.json" "${COCKPIT_DIR}/"
    install -m 644 "${SCRIPT_DIR}/src/index.html" "${COCKPIT_DIR}/"
    install -m 644 "${SCRIPT_DIR}/src/devs-permissions.js" "${COCKPIT_DIR}/"
    install -m 644 "${SCRIPT_DIR}/src/devs-permissions.css" "${COCKPIT_DIR}/"

    # Instalar bridge
    info "Instalando bridge helper..."
    install -m 755 "${SCRIPT_DIR}/bridge/cockpit-helper.sh" "${LIBEXEC_DIR}/"

    # Instalar scripts principais se --with-scripts
    if [[ "${WITH_SCRIPTS:-false}" == true ]]; then
        install_scripts
    fi

    # Garantir config base existe
    ensure_config

    # Restart cockpit
    info "Reiniciando Cockpit..."
    systemctl try-restart cockpit.socket 2>/dev/null || warn "Nao foi possivel reiniciar cockpit.socket"

    echo ""
    info "============================================="
    info " Instalacao concluida!"
    info "============================================="
    echo ""
    echo "  Acesse: https://$(hostname -f 2>/dev/null || hostname):9090"
    echo "  Menu lateral: DevOps Permissions"
    echo ""

    if [[ ! -x "${LIBEXEC_DIR}/devs_permissions_manager.sh" ]]; then
        warn "Script principal ainda nao instalado!"
        echo ""
        echo "  Copie os scripts para os caminhos FHS:"
        echo "    sudo cp devs_permissions_manager.sh ${LIBEXEC_DIR}/"
        echo "    sudo chmod +x ${LIBEXEC_DIR}/devs_permissions_manager.sh"
        echo ""
        echo "  Ou reinstale com: sudo $0 --with-scripts"
        echo ""
    fi
}

install_scripts() {
    info "Copiando scripts principais..."

    # Procurar os scripts em locais comuns
    local manager_src="" config_src=""
    local search_dirs=(
        "${SCRIPT_DIR}"
        "${SCRIPT_DIR}/.."
        "/root/bin"
        "/root"
        "/home/*/bin"
        "/opt/devs-permissions"
        "/usr/local/bin"
        "/usr/local/sbin"
    )

    for pattern in "${search_dirs[@]}"; do
        for dir in $pattern; do
            [[ -d "$dir" ]] || continue
            [[ -z "$manager_src" && -f "${dir}/devs_permissions_manager.sh" ]] && manager_src="${dir}/devs_permissions_manager.sh"
            [[ -z "$config_src" && -f "${dir}/devs_permissions.conf" ]] && config_src="${dir}/devs_permissions.conf"
        done
    done

    # Se nao encontrou nos locais comuns, busca no sistema todo
    if [[ -z "$manager_src" ]]; then
        info "  Buscando devs_permissions_manager.sh no sistema..."
        manager_src=$(find / -maxdepth 4 -name "devs_permissions_manager.sh" -type f 2>/dev/null | head -1)
    fi

    if [[ -n "$manager_src" ]]; then
        install -m 755 "$manager_src" "${LIBEXEC_DIR}/devs_permissions_manager.sh"
        info "  Manager: ${manager_src} -> ${LIBEXEC_DIR}/"
    else
        warn "  devs_permissions_manager.sh nao encontrado no sistema."
        warn "  Copie manualmente para: ${LIBEXEC_DIR}/devs_permissions_manager.sh"
    fi

    if [[ -n "$config_src" ]]; then
        # Só copia se não existir (não sobrescreve config do usuário)
        if [[ ! -f "${CONFIG_DIR}/devs_permissions.conf" ]]; then
            install -m 644 "$config_src" "${CONFIG_DIR}/devs_permissions.conf"
            info "  Config: ${config_src} -> ${CONFIG_DIR}/"
        else
            info "  Config ja existe em ${CONFIG_DIR}/, mantendo existente."
        fi
    fi
}

do_uninstall() {
    header "Removendo ${NAME}"

    # Remove todas as possíveis instalações
    local all_dirs=("$COCKPIT_DIR" "/usr/share/cockpit/devs-permissions-cockpit" "/usr/share/cockpit/devs_permissions")
    for dir in "${all_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            info "Plugin removido de ${dir}"
        fi
    done

    if [[ -f "${LIBEXEC_DIR}/cockpit-helper.sh" ]]; then
        rm -f "${LIBEXEC_DIR}/cockpit-helper.sh"
        info "Helper removido de ${LIBEXEC_DIR}"
    fi

    # Não remove scripts, config nem dados!
    if [[ -x "${LIBEXEC_DIR}/devs_permissions_manager.sh" ]]; then
        info "Scripts e config mantidos em ${LIBEXEC_DIR} e ${CONFIG_DIR}."
        info "Para remover tudo: rm -rf ${LIBEXEC_DIR} ${CONFIG_DIR}"
    fi

    systemctl try-restart cockpit.socket 2>/dev/null || true
    info "Desinstalacao concluida."
}

do_build_rpm() {
    header "Gerando RPM"

    if ! command -v rpmbuild &>/dev/null; then
        error "rpmbuild nao encontrado. Instale: sudo dnf install rpm-build"
        exit 1
    fi

    cd "${SCRIPT_DIR}"
    make rpm
}

# === MAIN ===

ACTION="install"
WITH_SCRIPTS=false

for arg in "$@"; do
    case "$arg" in
        --uninstall)     ACTION="uninstall" ;;
        --with-scripts)  WITH_SCRIPTS=true ;;
        --build-rpm)     ACTION="build-rpm" ;;
        -h|--help)
            echo "Uso: $0 [OPCOES]"
            echo ""
            echo "OPCOES:"
            echo "  (sem opcoes)       Instala o plugin Cockpit"
            echo "  --with-scripts     Instala plugin + copia scripts do manager"
            echo "  --uninstall        Remove o plugin (mantem scripts e dados)"
            echo "  --build-rpm        Gera pacote RPM sem instalar"
            echo "  -h, --help         Esta ajuda"
            exit 0
            ;;
        *)
            error "Opcao desconhecida: $arg"
            exit 1
            ;;
    esac
done

check_root "$@"

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    build-rpm) do_build_rpm ;;
esac
