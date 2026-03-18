#!/usr/bin/env bash
#===============================================================================
#
#   AUTO-INSTALL - DevOps Permissions Manager + Cockpit Plugin
#
#   Instala TUDO do zero em um servidor limpo:
#     - Dependencias do sistema (git, cockpit, curl)
#     - Cockpit habilitado e rodando
#     - Plugin web (devs-permissions-cockpit)
#     - Manager CLI (devs_permissions_manager.sh)
#     - Configuracao base
#     - Symlink CLI global
#
#   DISTROS SUPORTADAS:
#     - RHEL/CentOS/Rocky Linux 8+
#     - Ubuntu 20.04+
#     - Debian 11+
#
#   USO:
#     sudo bash auto-install.sh              # Instala tudo
#     sudo bash auto-install.sh --uninstall  # Remove plugin (mantem config/dados)
#     sudo bash auto-install.sh --purge      # Remove tudo incluindo dados
#     sudo bash auto-install.sh --help       # Ajuda
#
#   FONTE:
#     Se executado dentro do repositorio, usa arquivos locais.
#     Caso contrario, clona automaticamente do GitHub.
#
#===============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub repo para clone remoto
readonly GITHUB_REPO="https://github.com/andersonfas/devs_permissions_manager.git"

# Paths FHS
readonly COCKPIT_DIR="/usr/share/cockpit/devs-permissions"
readonly LIBEXEC_DIR="/usr/libexec/devs-permissions"
readonly CONFIG_DIR="/etc/devs-permissions"
readonly DATA_DIR="/var/lib/devs_permissions"
readonly LOG_DIR="/var/log/devs_audit"
readonly BACKUP_DIR="/var/backups/devs_permissions"
readonly CLI_SYMLINK="/usr/local/bin/devs-permissions"

# Variavel para rastrear se clonamos o repo (para cleanup)
CLONED_DIR=""
REPO_DIR=""

#===============================================================================
# CORES E UTILIDADES
#===============================================================================

if [[ -t 1 ]]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m' N='\033[0m' BOLD='\033[1m'
else
    R='' G='' Y='' B='' C='' N='' BOLD=''
fi

info()    { echo -e "${G}[INFO]${N} $*"; }
warn()    { echo -e "${Y}[WARN]${N} $*"; }
error()   { echo -e "${R}[ERRO]${N} $*" >&2; }
header()  { echo -e "\n${B}${BOLD}=== $* ===${N}"; }
success() { echo -e "${G}${BOLD}[OK]${N} $*"; }

cleanup_on_exit() {
    if [[ -n "$CLONED_DIR" && -d "$CLONED_DIR" ]]; then
        rm -rf "$CLONED_DIR"
    fi
}

trap cleanup_on_exit EXIT

#===============================================================================
# VERIFICACOES
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Execute como root: sudo bash $0 $*"
        exit 1
    fi
}

#===============================================================================
# DETECCAO DE DISTRIBUICAO
#===============================================================================

DISTRO_FAMILY=""
DISTRO_NAME=""
DISTRO_VERSION=""

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        error "Nao foi possivel detectar a distribuicao Linux (/etc/os-release nao encontrado)"
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    DISTRO_NAME="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-0}"

    case "$DISTRO_NAME" in
        rhel|centos|rocky|almalinux|ol|fedora)
            DISTRO_FAMILY="rhel"
            ;;
        ubuntu|debian|linuxmint|pop)
            DISTRO_FAMILY="debian"
            ;;
        *)
            error "Distribuicao nao suportada: ${DISTRO_NAME}"
            echo ""
            echo "Distribuicoes suportadas:"
            echo "  - RHEL/CentOS/Rocky/AlmaLinux 8+"
            echo "  - Ubuntu 20.04+"
            echo "  - Debian 11+"
            exit 1
            ;;
    esac

    info "Distribuicao detectada: ${PRETTY_NAME:-$DISTRO_NAME $DISTRO_VERSION} (familia: ${DISTRO_FAMILY})"
}

#===============================================================================
# DETECCAO DE FONTE (LOCAL vs GITHUB)
#===============================================================================

detect_source() {
    # Verifica se o script esta sendo executado dentro do repositorio
    if [[ -f "${SCRIPT_DIR}/devs-permissions-cockpit/src/manifest.json" && \
          -f "${SCRIPT_DIR}/devs_permissions_manager.sh" ]]; then
        REPO_DIR="$SCRIPT_DIR"
        info "Repositorio local detectado em: ${REPO_DIR}"
        return 0
    fi

    # Verifica diretorio atual
    if [[ -f "./devs-permissions-cockpit/src/manifest.json" && \
          -f "./devs_permissions_manager.sh" ]]; then
        REPO_DIR="$(pwd)"
        info "Repositorio local detectado em: ${REPO_DIR}"
        return 0
    fi

    # Nao encontrou localmente - precisa clonar
    REPO_DIR=""
    return 0
}

ensure_repo() {
    if [[ -n "$REPO_DIR" ]]; then
        return 0
    fi

    header "Clonando repositorio do GitHub"

    # Garantir que git esta instalado para o clone
    if ! command -v git &>/dev/null; then
        info "Instalando git para clonar o repositorio..."
        if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
            dnf install -y git 2>&1 | tail -1
        else
            apt-get update -qq && apt-get install -y -qq git 2>&1 | tail -1
        fi
    fi

    CLONED_DIR="/tmp/devs-permissions-install-$$"
    info "Clonando ${GITHUB_REPO} para ${CLONED_DIR}..."

    if ! git clone --depth 1 "$GITHUB_REPO" "$CLONED_DIR" 2>&1; then
        error "Falha ao clonar repositorio: ${GITHUB_REPO}"
        error "Verifique sua conexao de rede e tente novamente."
        exit 1
    fi

    REPO_DIR="$CLONED_DIR"
    success "Repositorio clonado com sucesso"
}

#===============================================================================
# VERIFICACAO DE ARQUIVOS OBRIGATORIOS
#===============================================================================

check_required_files() {
    local required=(
        "devs-permissions-cockpit/src/manifest.json"
        "devs-permissions-cockpit/src/index.html"
        "devs-permissions-cockpit/src/devs-permissions.js"
        "devs-permissions-cockpit/src/devs-permissions.css"
        "devs-permissions-cockpit/bridge/cockpit-helper.sh"
        "devs_permissions_manager.sh"
    )

    local missing=0
    for f in "${required[@]}"; do
        if [[ ! -f "${REPO_DIR}/${f}" ]]; then
            error "Arquivo obrigatorio nao encontrado: ${f}"
            missing=1
        fi
    done

    if [[ $missing -eq 1 ]]; then
        error "Arquivos obrigatorios faltando. Verifique o repositorio."
        exit 1
    fi

    success "Todos os arquivos obrigatorios encontrados"
}

#===============================================================================
# INSTALACAO DE DEPENDENCIAS
#===============================================================================

install_dependencies() {
    header "Instalando dependencias do sistema"

    if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
        info "Instalando pacotes via dnf..."
        dnf install -y \
            cockpit \
            cockpit-system \
            cockpit-bridge \
            git \
            curl \
            coreutils \
            bash \
            2>&1 | grep -E "^(Instalado|Installed|Complete|Nada|Nothing)" || true
    else
        info "Atualizando lista de pacotes..."
        apt-get update -qq 2>&1 | tail -1

        info "Instalando pacotes via apt..."
        apt-get install -y -qq \
            cockpit \
            git \
            curl \
            coreutils \
            bash \
            2>&1 | tail -3 || true
    fi

    # Verificar se cockpit foi instalado
    if ! command -v cockpit-bridge &>/dev/null; then
        error "Falha ao instalar o Cockpit. Verifique os logs do gerenciador de pacotes."
        exit 1
    fi

    success "Dependencias instaladas"
}

#===============================================================================
# HABILITAR COCKPIT
#===============================================================================

enable_cockpit() {
    header "Habilitando Cockpit"

    systemctl enable --now cockpit.socket 2>/dev/null || true

    if systemctl is-active --quiet cockpit.socket; then
        success "cockpit.socket ativo e habilitado"
    else
        warn "cockpit.socket pode nao estar ativo (sera iniciado no primeiro acesso)"
        systemctl enable cockpit.socket 2>/dev/null || true
    fi

    info "Cockpit acessivel em: https://$(hostname -f 2>/dev/null || hostname):9090"
}

#===============================================================================
# CRIAR DIRETORIOS
#===============================================================================

create_directories() {
    header "Criando diretorios"

    mkdir -p "$COCKPIT_DIR"
    mkdir -p "$LIBEXEC_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p -m 750 "${DATA_DIR}/temp_access"
    mkdir -p -m 750 "${DATA_DIR}/requests"
    mkdir -p -m 750 "${LOG_DIR}/sessions"
    mkdir -p -m 750 "$BACKUP_DIR"

    success "Diretorios criados"
}

#===============================================================================
# LIMPAR INSTALACOES ANTIGAS
#===============================================================================

cleanup_old_installs() {
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

#===============================================================================
# INSTALAR PLUGIN COCKPIT (FRONTEND)
#===============================================================================

install_plugin() {
    header "Instalando plugin Cockpit (frontend)"

    local src="${REPO_DIR}/devs-permissions-cockpit/src"

    install -m 644 "${src}/manifest.json"         "${COCKPIT_DIR}/"
    install -m 644 "${src}/index.html"            "${COCKPIT_DIR}/"
    install -m 644 "${src}/devs-permissions.js"   "${COCKPIT_DIR}/"
    install -m 644 "${src}/devs-permissions.css"  "${COCKPIT_DIR}/"

    success "Plugin frontend instalado em ${COCKPIT_DIR}/"
}

#===============================================================================
# INSTALAR BRIDGE (COCKPIT-HELPER)
#===============================================================================

install_bridge() {
    header "Instalando bridge (cockpit-helper)"

    install -m 755 "${REPO_DIR}/devs-permissions-cockpit/bridge/cockpit-helper.sh" "${LIBEXEC_DIR}/"

    success "Bridge instalado em ${LIBEXEC_DIR}/cockpit-helper.sh"
}

#===============================================================================
# INSTALAR MANAGER (CLI)
#===============================================================================

install_manager() {
    header "Instalando manager CLI"

    install -m 755 "${REPO_DIR}/devs_permissions_manager.sh" "${LIBEXEC_DIR}/"

    success "Manager instalado em ${LIBEXEC_DIR}/devs_permissions_manager.sh"
}

#===============================================================================
# INSTALAR CONFIGURACAO
#===============================================================================

install_config() {
    header "Configurando"

    local config_dest="${CONFIG_DIR}/devs_permissions.conf"

    if [[ -f "$config_dest" ]]; then
        info "Configuracao existente encontrada em ${config_dest} - mantendo."
    elif [[ -f "${REPO_DIR}/devs_permissions.conf" ]]; then
        install -m 644 "${REPO_DIR}/devs_permissions.conf" "$config_dest"
        success "Configuracao instalada de ${REPO_DIR}/devs_permissions.conf"
    else
        info "Criando configuracao base..."
        cat > "$config_dest" <<'CONF'
#===============================================================================
# DevOps Permissions Manager - Configuracao
# Gerado automaticamente pelo auto-install.sh
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

# Notificacoes
WEBHOOK_URL=""
WEBHOOK_TYPE="slack"
NOTIFY_ON_EXEC=false
NOTIFY_ON_TEMP_ACCESS=true
NOTIFY_ON_REQUEST=true
NOTIFY_ON_SUSPICIOUS=true
REPORT_EMAIL=""
CONF
        chmod 644 "$config_dest"
        success "Configuracao base criada em ${config_dest}"
    fi
}

#===============================================================================
# CRIAR SYMLINK CLI
#===============================================================================

create_cli_symlink() {
    header "Criando symlink CLI"

    ln -sf "${LIBEXEC_DIR}/devs_permissions_manager.sh" "$CLI_SYMLINK"

    if [[ -x "$CLI_SYMLINK" ]]; then
        success "CLI disponivel como: devs-permissions"
    else
        warn "Symlink criado mas pode nao estar no PATH"
    fi
}

#===============================================================================
# SELINUX
#===============================================================================

handle_selinux() {
    if ! command -v getenforce &>/dev/null; then
        return 0
    fi

    local selinux_status
    selinux_status="$(getenforce 2>/dev/null || echo "Disabled")"

    if [[ "$selinux_status" == "Disabled" ]]; then
        return 0
    fi

    header "Configurando SELinux"

    info "SELinux detectado (${selinux_status}), restaurando contextos..."
    restorecon -R "$COCKPIT_DIR"  2>/dev/null || true
    restorecon -R "$LIBEXEC_DIR" 2>/dev/null || true
    restorecon -R "$CONFIG_DIR"  2>/dev/null || true

    if command -v semanage &>/dev/null; then
        semanage fcontext -a -t cockpit_ws_exec_t "${LIBEXEC_DIR}/cockpit-helper.sh" 2>/dev/null || true
        semanage fcontext -a -t cockpit_ws_exec_t "${LIBEXEC_DIR}/devs_permissions_manager.sh" 2>/dev/null || true
        restorecon -v "${LIBEXEC_DIR}/cockpit-helper.sh" 2>/dev/null || true
        restorecon -v "${LIBEXEC_DIR}/devs_permissions_manager.sh" 2>/dev/null || true
    fi

    if command -v setsebool &>/dev/null; then
        setsebool -P cockpit_enable_shell 1 2>/dev/null || true
    fi

    success "Contextos SELinux aplicados"
}

#===============================================================================
# REINICIAR COCKPIT
#===============================================================================

restart_cockpit() {
    header "Reiniciando Cockpit"

    systemctl try-restart cockpit.socket 2>/dev/null || true

    if systemctl is-active --quiet cockpit.socket; then
        success "Cockpit reiniciado com sucesso"
    else
        warn "cockpit.socket nao esta ativo (sera iniciado no primeiro acesso na porta 9090)"
    fi
}

#===============================================================================
# VERIFICAR INSTALACAO
#===============================================================================

verify_installation() {
    header "Verificando instalacao"

    local errors=0

    # Frontend
    for f in manifest.json index.html devs-permissions.js devs-permissions.css; do
        if [[ -f "${COCKPIT_DIR}/${f}" ]]; then
            success "  ${COCKPIT_DIR}/${f}"
        else
            error "  FALTANDO: ${COCKPIT_DIR}/${f}"
            errors=$((errors + 1))
        fi
    done

    # Bridge
    if [[ -x "${LIBEXEC_DIR}/cockpit-helper.sh" ]]; then
        success "  ${LIBEXEC_DIR}/cockpit-helper.sh"
    else
        error "  FALTANDO: ${LIBEXEC_DIR}/cockpit-helper.sh"
        errors=$((errors + 1))
    fi

    # Manager
    if [[ -x "${LIBEXEC_DIR}/devs_permissions_manager.sh" ]]; then
        success "  ${LIBEXEC_DIR}/devs_permissions_manager.sh"
    else
        error "  FALTANDO: ${LIBEXEC_DIR}/devs_permissions_manager.sh"
        errors=$((errors + 1))
    fi

    # Config
    if [[ -f "${CONFIG_DIR}/devs_permissions.conf" ]]; then
        success "  ${CONFIG_DIR}/devs_permissions.conf"
    else
        error "  FALTANDO: ${CONFIG_DIR}/devs_permissions.conf"
        errors=$((errors + 1))
    fi

    # CLI symlink
    if [[ -L "$CLI_SYMLINK" ]]; then
        success "  ${CLI_SYMLINK} -> $(readlink "$CLI_SYMLINK")"
    else
        warn "  Symlink CLI nao encontrado: ${CLI_SYMLINK}"
    fi

    # Cockpit
    if systemctl is-enabled --quiet cockpit.socket 2>/dev/null; then
        success "  cockpit.socket habilitado"
    else
        warn "  cockpit.socket nao habilitado"
    fi

    if [[ $errors -gt 0 ]]; then
        error "Instalacao incompleta: ${errors} arquivo(s) faltando"
        return 1
    fi

    return 0
}

#===============================================================================
# RESUMO FINAL
#===============================================================================

print_summary() {
    local hostname_val
    hostname_val="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'seu-servidor')"

    echo ""
    echo -e "${G}${BOLD}=============================================${N}"
    echo -e "${G}${BOLD} DevOps Permissions Manager - Instalado!${N}"
    echo -e "${G}${BOLD}=============================================${N}"
    echo ""
    echo -e " ${C}Web UI:${N}  https://${hostname_val}:9090"
    echo -e "          Menu lateral -> ${BOLD}DevOps Permissions${N}"
    echo ""
    echo -e " ${C}CLI:${N}     devs-permissions --help"
    echo "          devs-permissions add-user joao"
    echo "          devs-permissions list-users"
    echo "          devs-permissions promote joao exec"
    echo "          devs-permissions grant-temp joao --hours 4"
    echo ""
    echo -e " ${C}Config:${N}  ${CONFIG_DIR}/devs_permissions.conf"
    echo -e " ${C}Logs:${N}    ${LOG_DIR}/"
    echo -e " ${C}Backups:${N} ${BACKUP_DIR}/"
    echo ""
    echo -e " ${Y}NOTA:${N} Verifique que a porta 9090 esta acessivel no firewall."
    echo -e "       ${Y}firewalld:${N} firewall-cmd --add-service=cockpit --permanent && firewall-cmd --reload"
    echo -e "       ${Y}ufw:${N}       ufw allow 9090/tcp"
    echo ""
    echo -e "${G}${BOLD}=============================================${N}"
    echo ""
}

#===============================================================================
# INSTALACAO COMPLETA
#===============================================================================

do_install() {
    echo ""
    echo -e "${B}${BOLD}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${B}${BOLD}║  DevOps Permissions Manager - Auto Install v${SCRIPT_VERSION}  ║${N}"
    echo -e "${B}${BOLD}╚══════════════════════════════════════════════════╝${N}"
    echo ""

    check_root "$@"
    detect_distro
    detect_source
    ensure_repo
    check_required_files
    install_dependencies
    enable_cockpit
    create_directories
    cleanup_old_installs
    install_plugin
    install_bridge
    install_manager
    install_config
    create_cli_symlink
    handle_selinux
    restart_cockpit

    if verify_installation; then
        print_summary
    else
        echo ""
        error "A instalacao teve problemas. Verifique os erros acima."
        exit 1
    fi
}

#===============================================================================
# DESINSTALACAO
#===============================================================================

do_uninstall() {
    local purge="${1:-false}"

    echo ""
    header "Removendo DevOps Permissions Manager"
    check_root

    # Plugin frontend
    local all_dirs=("$COCKPIT_DIR" "/usr/share/cockpit/devs-permissions-cockpit" "/usr/share/cockpit/devs_permissions")
    for dir in "${all_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            info "Plugin removido de ${dir}"
        fi
    done

    # Bridge helper
    if [[ -f "${LIBEXEC_DIR}/cockpit-helper.sh" ]]; then
        rm -f "${LIBEXEC_DIR}/cockpit-helper.sh"
        info "Bridge removido"
    fi

    # Manager
    if [[ -f "${LIBEXEC_DIR}/devs_permissions_manager.sh" ]]; then
        rm -f "${LIBEXEC_DIR}/devs_permissions_manager.sh"
        info "Manager removido"
    fi

    # Symlink CLI
    if [[ -L "$CLI_SYMLINK" ]]; then
        rm -f "$CLI_SYMLINK"
        info "Symlink CLI removido"
    fi

    # Limpar diretorio libexec se vazio
    rmdir "${LIBEXEC_DIR}" 2>/dev/null || true

    if [[ "$purge" == "true" ]]; then
        warn "Modo purge: removendo configuracao, dados, logs e backups..."
        rm -rf "$CONFIG_DIR"
        rm -rf "$DATA_DIR"
        rm -rf "$LOG_DIR"
        rm -rf "$BACKUP_DIR"
        info "Dados e configuracao removidos"
    else
        info "Configuracao mantida em: ${CONFIG_DIR}/"
        info "Dados mantidos em: ${DATA_DIR}/"
        info "Para remover tudo: $0 --purge"
    fi

    # Reiniciar cockpit
    systemctl try-restart cockpit.socket 2>/dev/null || true

    echo ""
    success "Desinstalacao concluida."
    info "O Cockpit nao foi desinstalado (pode estar sendo usado por outros plugins)."
    echo ""
}

#===============================================================================
# MAIN
#===============================================================================

show_help() {
    echo "DevOps Permissions Manager - Auto Install v${SCRIPT_VERSION}"
    echo ""
    echo "Uso: sudo bash $0 [OPCAO]"
    echo ""
    echo "OPCOES:"
    echo "  (sem opcoes)       Instala tudo (dependencias + cockpit + plugin + CLI)"
    echo "  --uninstall        Remove o plugin (mantem config e dados)"
    echo "  --purge            Remove tudo incluindo config, dados, logs e backups"
    echo "  -h, --help         Mostra esta ajuda"
    echo ""
    echo "EXEMPLOS:"
    echo "  # Instalacao completa em servidor novo:"
    echo "  curl -fsSL https://raw.githubusercontent.com/andersonfas/devs_permissions_manager/main/auto-install.sh | sudo bash"
    echo ""
    echo "  # Ou clone e instale:"
    echo "  git clone https://github.com/andersonfas/devs_permissions_manager.git"
    echo "  cd devs_permissions_manager"
    echo "  sudo bash auto-install.sh"
    echo ""
}

ACTION="install"

for arg in "$@"; do
    case "$arg" in
        --uninstall)  ACTION="uninstall" ;;
        --purge)      ACTION="purge" ;;
        -h|--help)    show_help; exit 0 ;;
        *)
            error "Opcao desconhecida: $arg"
            echo "Use: $0 --help"
            exit 1
            ;;
    esac
done

case "$ACTION" in
    install)   do_install "$@" ;;
    uninstall) do_uninstall "false" ;;
    purge)     do_uninstall "true" ;;
esac
