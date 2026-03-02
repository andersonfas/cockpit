#!/usr/bin/env bash
#===============================================================================
#
#          ARQUIVO: devs_permissions_manager.sh
#
#         DESCRIÇÃO: Gerenciador Enterprise de Permissões para Desenvolvedores
#                    Sistema completo de controle de acesso a Docker, logs e configs
#
#          VERSÃO: 5.0.0 (Production Ready)
#          CRIADO: 2025-01-23
#      ATUALIZADO: 2026-01-28
#         AMBIENTE: RHEL/CentOS/Rocky Linux 8+, Ubuntu 20.04+
#
#           EQUIPE: DevOps - DETRAN-CE
#       LOCALIZAÇÃO: /root/bin/devs_permissions_manager.sh
#
#   FUNCIONALIDADES:
#       • Gestão automática de usuários e grupos
#       • Três níveis de acesso (básico, exec, webconf)
#       • Controle por ambiente (dev/staging/prod)
#       • Restrição por time/projeto (containers específicos)
#       • Horário de acesso permitido
#       • Acesso temporário com expiração
#       • Session recording (auditoria de comandos)
#       • Revogação automática por inatividade
#       • Self-service com aprovação
#       • Dashboard HTML e terminal
#       • Integração Slack/Teams/Discord
#
#   CHANGELOG v5.0.0:
#       • Correção de todos os bugs com set -o errexit
#       • Sistema de times para restrição por container
#       • Dashboard HTML exportável
#       • Melhor tratamento de erros
#       • Código refatorado e otimizado
#       • Testes de validação integrados
#
#===============================================================================

# Desabilita errexit globalmente - vamos tratar erros manualmente para mais controle
set +o errexit
set -o nounset
set -o pipefail

# Trap para limpeza em caso de erro
trap 'cleanup_on_exit' EXIT
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

#===============================================================================
# CONSTANTES GLOBAIS (readonly)
#===============================================================================
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="5.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PID=$$
readonly LOCK_FILE="/var/run/devs_permissions.lock"

# Configuração padrão
CONFIG_FILE="${SCRIPT_DIR}/devs_permissions.conf"

#===============================================================================
# VARIÁVEIS PADRÃO (podem ser sobrescritas pelo config)
#===============================================================================

# Grupos
GRUPO_DEV="devs"
GRUPO_DEV_EXEC="devs_exec"
GRUPO_DEV_WEBCONF="devs_webconf"

# Arquivos e diretórios
SUDO_FILE="/etc/sudoers.d/devs_permissoes"
BACKUP_DIR="/var/backups/devs_permissions"
LOG_FILE="/var/log/devs_permissions_manager.log"
AUDIT_LOG_DIR="/var/log/devs_audit"
AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/docker_audit.log"
SESSION_LOG_DIR="${AUDIT_LOG_DIR}/sessions"
DOCKER_WRAPPER_PATH="/usr/local/bin/docker-devs"
TEMP_ACCESS_DIR="/var/lib/devs_permissions/temp_access"
REQUESTS_DIR="/var/lib/devs_permissions/requests"
CRON_FILE="/etc/cron.d/devs_permissions_jobs"
DASHBOARD_DIR="/var/www/html/devs-dashboard"

# Notificações
WEBHOOK_URL=""
WEBHOOK_TYPE="slack"
NOTIFY_ON_EXEC=true
NOTIFY_ON_TEMP_ACCESS=true
NOTIFY_ON_REQUEST=true
NOTIFY_ON_SUSPICIOUS=true
REPORT_EMAIL=""

# Configurações de usuário
DEFAULT_SHELL="/bin/bash"
AUTO_CREATE_USERS=true
AUTO_CREATE_GROUPS=true

# Controle de acesso por horário
ACCESS_HOURS_ENABLED=false
ACCESS_HOURS_START="08:00"
ACCESS_HOURS_END="20:00"
ACCESS_HOURS_WEEKDAYS_ONLY=true

# Controle por ambiente
ENVIRONMENT="production"
PROD_REQUIRES_APPROVAL=true
PROD_MAX_TEMP_HOURS=4
STAGING_MAX_TEMP_HOURS=12
DEV_MAX_TEMP_HOURS=48

# Inatividade
INACTIVITY_DAYS=30
AUTO_REVOKE_INACTIVE=true

# Limites
MAX_TEMP_HOURS=24
MAX_CONCURRENT_SESSIONS=3

# Times/Projetos
TEAM_RESTRICTION_ENABLED=false

# Arrays (serão preenchidos pelo config)
declare -a USUARIOS=()
declare -a USUARIOS_EXEC=()
declare -a USUARIOS_WEBCONF=()
declare -a TEAMS=()
declare -a LOG_DIRS_ALLOWED=(
    "/var/log/nginx"
    "/var/log/httpd"
    "/var/log/tomcat"
    "/var/log/apache2"
)
declare -a WEBCONF_DIRS_ALLOWED=(
    "/etc/nginx/conf.d"
    "/etc/httpd/conf.d"
)
declare -a WEBCONF_SERVICES_ALLOWED=(
    "nginx"
    "httpd"
)
declare -a DOCKER_EXEC_COMMANDS_ALLOWED=(
    "/bin/bash"
    "/bin/sh"
    "bash"
    "sh"
)
declare -a BLOCKED_COMMANDS=(
    "rm -rf /"
    "rm -rf /*"
    "dd if=/dev"
    "mkfs"
    "> /dev/sd"
    "chmod 777 /"
    "chmod -R 777 /"
)
declare -a DOCKER_LOGS_PATTERNS=()
declare -a DOCKER_CONTAINER_PATTERNS=()
declare -a PROTECTED_USERS=("root" "sysadmin")

# Flags de execução
DRY_RUN=false
VERBOSE=false
FORCE=false
SKIP_BACKUP=false
COMMAND=""

# Parâmetros de comando
CMD_USER=""
CMD_HOURS=24
CMD_EXEC=false
CMD_WEBCONF=false
CMD_DAYS=7
CMD_FORMAT="text"
CMD_REASON=""
CMD_APPROVER=""
CMD_REQUEST_ID=""
CMD_ENVIRONMENT=""
CMD_REMOVE_HOME=false

#===============================================================================
# CORES (detecta se terminal suporta)
#===============================================================================
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly MAGENTA='\033[0;35m'
    readonly WHITE='\033[1;37m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' WHITE='' BOLD='' DIM='' NC=''
fi

#===============================================================================
# FUNÇÕES DE UTILIDADE
#===============================================================================

# Timestamp formatado
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_date() { date '+%Y-%m-%d'; }
_epoch() { date '+%s'; }

# Limpeza ao sair
cleanup_on_exit() {
    local exit_code=$?
    # Remove lock se existir e foi criado por este processo
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ "$lock_pid" == "$SCRIPT_PID" ]]; then
            rm -f "$LOCK_FILE" 2>/dev/null || true
        fi
    fi
    exit $exit_code
}

# Handler de erro
error_handler() {
    local line="$1"
    local cmd="$2"
    # Só loga se VERBOSE estiver ativo - erros são normais em algumas operações
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${DIM}[DEBUG] Erro na linha $line: $cmd${NC}" >&2
    fi
}

# Adquire lock exclusivo
acquire_lock() {
    local max_wait=30
    local waited=0
    
    while [[ -f "$LOCK_FILE" ]]; do
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # Verifica se o processo ainda existe
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
            break
        fi
        
        if [[ $waited -ge $max_wait ]]; then
            log_error "Timeout aguardando lock. Outro processo em execução?"
            return 1
        fi
        
        sleep 1
        ((waited++))
    done
    
    echo "$SCRIPT_PID" > "$LOCK_FILE"
    return 0
}

# Libera lock
release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

#===============================================================================
# FUNÇÕES DE LOG
#===============================================================================

# Função base de log
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(_ts)"
    
    # Cria diretório de log se não existir
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null
    
    # Escreve no arquivo de log
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    # Saída no terminal
    case "$level" in
        INFO)    echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR)   echo -e "${RED}[ERRO]${NC} $message" >&2 ;;
        DEBUG)   [[ "$VERBOSE" == true ]] && echo -e "${DIM}[DEBUG]${NC} $message" ;;
        OK)      echo -e "${GREEN}[OK]${NC} $message" ;;
        DRY)     echo -e "${BLUE}[DRY-RUN]${NC} $message" ;;
        ALERT)   echo -e "${RED}${BOLD}[ALERT]${NC} $message" ;;
    esac
}

log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { _log DEBUG "$@"; }
log_ok()    { _log OK "$@"; }
log_dry()   { _log DRY "$@"; }
log_alert() { _log ALERT "$@"; }

# Log de auditoria estruturado (JSON)
audit_log() {
    local action="$1"
    local user="${2:-unknown}"
    local details="${3:-}"
    
    # Cria diretório se não existir
    [[ ! -d "$AUDIT_LOG_DIR" ]] && mkdir -p "$AUDIT_LOG_DIR" 2>/dev/null
    
    # Obtém IP de origem
    local source_ip="local"
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        source_ip="${SSH_CLIENT%% *}"
    fi
    
    # Monta JSON
    local entry
    entry=$(cat <<EOF
{"timestamp":"$(_ts)","action":"$action","user":"$user","details":"$details","source_ip":"$source_ip","tty":"${SSH_TTY:-console}","environment":"$ENVIRONMENT","pid":"$$"}
EOF
)
    
    echo "$entry" >> "$AUDIT_LOG_FILE" 2>/dev/null || true
    
    # Alerta para ações suspeitas
    if [[ "$action" == *"BLOCKED"* ]] || [[ "$action" == *"SUSPICIOUS"* ]]; then
        send_alert "🚨 Ação Suspeita" "Usuário: $user | Ação: $action | Detalhes: $details"
    fi
}

# Session recording
session_log() {
    local user="$1"
    local container="$2"
    local command="$3"
    
    [[ ! -d "$SESSION_LOG_DIR" ]] && mkdir -p "$SESSION_LOG_DIR" 2>/dev/null
    
    local session_file="${SESSION_LOG_DIR}/${user}_$(_date).log"
    echo "[$(_ts)] container=$container command=\"$command\"" >> "$session_file" 2>/dev/null || true
}

#===============================================================================
# FUNÇÕES DE NOTIFICAÇÃO
#===============================================================================

send_webhook() {
    local title="$1"
    local message="$2"
    local color="${3:-warning}"
    
    [[ -z "$WEBHOOK_URL" ]] && return 0
    
    # Escapa caracteres especiais no JSON
    title="${title//\"/\\\"}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"
    
    local payload=""
    
    case "$WEBHOOK_TYPE" in
        slack)
            local slack_color="warning"
            [[ "$color" == "success" ]] && slack_color="good"
            [[ "$color" == "danger" ]] && slack_color="danger"
            payload="{\"text\":\"$title\",\"attachments\":[{\"color\":\"$slack_color\",\"text\":\"$message\",\"footer\":\"DevOps Permissions Manager v$SCRIPT_VERSION | $ENVIRONMENT\"}]}"
            ;;
        teams)
            payload="{\"@type\":\"MessageCard\",\"summary\":\"$title\",\"themeColor\":\"0076D7\",\"title\":\"$title\",\"text\":\"$message\"}"
            ;;
        discord)
            payload="{\"content\":\"**$title**\\n$message\"}"
            ;;
    esac
    
    # Envia em background para não bloquear
    if command -v curl &>/dev/null; then
        curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$WEBHOOK_URL" &>/dev/null &
    fi
}

send_alert() {
    local title="$1"
    local message="$2"
    send_webhook "$title" "$message" "danger"
}

notify_temp_access() {
    local user="$1"
    local hours="$2"
    local action="$3"
    
    [[ "$NOTIFY_ON_TEMP_ACCESS" != true ]] && return 0
    
    local emoji="🔓"
    [[ "$action" == "revoked" ]] && emoji="🔒"
    
    send_webhook "${emoji} Acesso Temporário ${action^}" "Usuário: *$user*\nDuração: ${hours}h\nAmbiente: $ENVIRONMENT"
}

notify_request() {
    local user="$1"
    local request_id="$2"
    local hours="$3"
    local reason="$4"
    
    [[ "$NOTIFY_ON_REQUEST" != true ]] && return 0
    
    send_webhook "📋 Nova Solicitação de Acesso" "Usuário: *$user*\nHoras: $hours\nMotivo: $reason\nID: $request_id\n\nPara aprovar: \`$SCRIPT_NAME approve --request-id $request_id\`"
}

#===============================================================================
# FUNÇÕES DE VALIDAÇÃO
#===============================================================================

# Verifica se é root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root"
        log_error "Use: sudo $SCRIPT_NAME $*"
        exit 1
    fi
}

# Verifica dependências
check_dependencies() {
    local missing=()
    local deps=(getent useradd usermod groupadd gpasswd chown chmod visudo setfacl)
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Opcionais mas recomendados
    local optional=(curl jq)
    local optional_missing=()
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependências obrigatórias não encontradas: ${missing[*]}"
        exit 1
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_warn "Dependências opcionais não encontradas: ${optional_missing[*]}"
    fi
}

# Verifica se usuário existe
user_exists() {
    local user="$1"
    id "$user" &>/dev/null
    return $?
}

# Verifica se grupo existe
group_exists() {
    local group="$1"
    getent group "$group" &>/dev/null
    return $?
}

# Verifica se usuário está no grupo
user_in_group() {
    local user="$1"
    local group="$2"
    
    user_exists "$user" || return 1
    id -nG "$user" 2>/dev/null | grep -qw "$group"
    return $?
}

# Valida nome de usuário
validate_username() {
    local user="$1"
    
    # Deve ter entre 1 e 32 caracteres
    if [[ ${#user} -lt 1 ]] || [[ ${#user} -gt 32 ]]; then
        log_error "Nome de usuário deve ter entre 1 e 32 caracteres"
        return 1
    fi
    
    # Deve começar com letra minúscula ou underscore
    if [[ ! "$user" =~ ^[a-z_] ]]; then
        log_error "Nome de usuário deve começar com letra minúscula ou _"
        return 1
    fi
    
    # Só pode conter letras, números, underscore, hífen e ponto
    if [[ ! "$user" =~ ^[a-z_][a-z0-9._-]*$ ]]; then
        log_error "Nome de usuário contém caracteres inválidos"
        return 1
    fi
    
    return 0
}

# Verifica horário de acesso
check_access_hours() {
    [[ "$ACCESS_HOURS_ENABLED" != true ]] && return 0
    
    local current_hour
    current_hour=$(date '+%H:%M')
    local current_dow
    current_dow=$(date '+%u')  # 1=Monday, 7=Sunday
    
    # Verifica dia da semana
    if [[ "$ACCESS_HOURS_WEEKDAYS_ONLY" == true ]] && [[ $current_dow -gt 5 ]]; then
        log_warn "Acesso bloqueado: fim de semana"
        return 1
    fi
    
    # Verifica horário
    if [[ "$current_hour" < "$ACCESS_HOURS_START" ]] || [[ "$current_hour" > "$ACCESS_HOURS_END" ]]; then
        log_warn "Acesso bloqueado: fora do horário ($ACCESS_HOURS_START - $ACCESS_HOURS_END)"
        return 1
    fi
    
    return 0
}

# Retorna máximo de horas por ambiente
get_max_temp_hours() {
    case "$ENVIRONMENT" in
        production)  echo "$PROD_MAX_TEMP_HOURS" ;;
        staging)     echo "$STAGING_MAX_TEMP_HOURS" ;;
        development) echo "$DEV_MAX_TEMP_HOURS" ;;
        *)           echo "$MAX_TEMP_HOURS" ;;
    esac
}

#===============================================================================
# FUNÇÕES DE TIMES/PROJETOS
#===============================================================================

# Retorna o time de um usuário
get_user_team() {
    local user="$1"
    
    [[ "$TEAM_RESTRICTION_ENABLED" != true ]] && return 1
    [[ ${#TEAMS[@]} -eq 0 ]] && return 1
    
    for team in "${TEAMS[@]}"; do
        local users_var="TEAM_${team}_USERS[@]"
        
        # Verifica se a variável existe
        if declare -p "TEAM_${team}_USERS" &>/dev/null; then
            local -a users_array
            eval "users_array=(\"\${$users_var}\")"
            
            for team_user in "${users_array[@]}"; do
                if [[ "$team_user" == "$user" ]]; then
                    echo "$team"
                    return 0
                fi
            done
        fi
    done
    
    return 1
}

# Retorna TODOS os times de um usuário (suporta múltiplos times)
get_user_teams() {
    local user="$1"
    local -a user_teams=()
    
    [[ "$TEAM_RESTRICTION_ENABLED" != true ]] && return 1
    [[ ${#TEAMS[@]} -eq 0 ]] && return 1
    
    for team in "${TEAMS[@]}"; do
        local users_var="TEAM_${team}_USERS[@]"
        
        if declare -p "TEAM_${team}_USERS" &>/dev/null; then
            local -a users_array
            eval "users_array=(\"\${$users_var}\")"
            
            for team_user in "${users_array[@]}"; do
                if [[ "$team_user" == "$user" ]]; then
                    user_teams+=("$team")
                    break
                fi
            done
        fi
    done
    
    if [[ ${#user_teams[@]} -gt 0 ]]; then
        echo "${user_teams[*]}"
        return 0
    fi
    
    return 1
}

# Retorna containers de TODOS os times de um usuário
get_user_all_containers() {
    local user="$1"
    local -a all_containers=()
    
    local teams_str
    if teams_str=$(get_user_teams "$user" 2>/dev/null); then
        read -ra user_teams <<< "$teams_str"
        for team in "${user_teams[@]}"; do
            local containers_var="TEAM_${team}_CONTAINERS[@]"
            if declare -p "TEAM_${team}_CONTAINERS" &>/dev/null; then
                local -a team_containers
                eval "team_containers=(\"\${$containers_var}\")"
                all_containers+=("${team_containers[@]}")
            fi
        done
    fi
    
    if [[ ${#all_containers[@]} -gt 0 ]]; then
        echo "${all_containers[*]}"
    else
        echo "*"
    fi
}

# Retorna containers permitidos para um time
get_team_containers() {
    local team="$1"
    
    local containers_var="TEAM_${team}_CONTAINERS[@]"
    
    if declare -p "TEAM_${team}_CONTAINERS" &>/dev/null; then
        eval "echo \"\${$containers_var}\""
    else
        echo "*"
    fi
}

# Verifica se usuário tem restrição de time
user_has_team_restriction() {
    local user="$1"
    
    [[ "$TEAM_RESTRICTION_ENABLED" != true ]] && return 1
    
    local team
    if team=$(get_user_team "$user"); then
        return 0
    fi
    return 1
}

#===============================================================================
# CARREGAMENTO DE CONFIGURAÇÃO
#===============================================================================

load_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_warn "Arquivo de configuração não encontrado: $config_file"
        log_warn "Usando valores padrão"
        return 0
    fi
    
    log_info "Carregando: $config_file"
    
    # Valida sintaxe antes de carregar
    if ! bash -n "$config_file" 2>/dev/null; then
        log_error "Erro de sintaxe no arquivo de configuração"
        return 1
    fi
    
    # Carrega configuração
    # shellcheck source=/dev/null
    source "$config_file"
    
    # Garante valores padrão para variáveis críticas
    GRUPO_DEV="${GRUPO_DEV:-devs}"
    GRUPO_DEV_EXEC="${GRUPO_DEV_EXEC:-devs_exec}"
    GRUPO_DEV_WEBCONF="${GRUPO_DEV_WEBCONF:-devs_webconf}"
    ENVIRONMENT="${ENVIRONMENT:-production}"
    TEAM_RESTRICTION_ENABLED="${TEAM_RESTRICTION_ENABLED:-false}"
    
    # Garante que arrays existem
    [[ -z "${USUARIOS+x}" ]] && USUARIOS=()
    [[ -z "${USUARIOS_EXEC+x}" ]] && USUARIOS_EXEC=()
    [[ -z "${USUARIOS_WEBCONF+x}" ]] && USUARIOS_WEBCONF=()
    [[ -z "${TEAMS+x}" ]] && TEAMS=()
    [[ -z "${LOG_DIRS_ALLOWED+x}" ]] && LOG_DIRS_ALLOWED=()
    [[ -z "${WEBCONF_DIRS_ALLOWED+x}" ]] && WEBCONF_DIRS_ALLOWED=()
    [[ -z "${WEBCONF_SERVICES_ALLOWED+x}" ]] && WEBCONF_SERVICES_ALLOWED=()
    [[ -z "${DOCKER_EXEC_COMMANDS_ALLOWED+x}" ]] && DOCKER_EXEC_COMMANDS_ALLOWED=("/bin/bash" "/bin/sh" "bash" "sh")
    
    # Override de ambiente via CLI
    if [[ -n "$CMD_ENVIRONMENT" ]]; then
        ENVIRONMENT="$CMD_ENVIRONMENT"
    fi
    
    log_ok "Configuração carregada"
    log_debug "Ambiente: $ENVIRONMENT"
    log_debug "Usuários básicos: ${#USUARIOS[@]}"
    log_debug "Usuários exec: ${#USUARIOS_EXEC[@]}"
    log_debug "Usuários webconf: ${#USUARIOS_WEBCONF[@]}"
    log_debug "Times: ${#TEAMS[@]}"
    
    return 0
}

#===============================================================================
# FUNÇÕES DE CONFIRMAÇÃO
#===============================================================================

confirm_action() {
    local message="$1"
    
    [[ "$FORCE" == true ]] && return 0
    
    echo -e "${YELLOW}$message${NC}"
    read -r -p "Continuar? [s/N]: " response
    
    if [[ "$response" =~ ^[sS]$ ]]; then
        return 0
    else
        return 1
    fi
}

confirm_destructive() {
    local message="$1"
    local confirm_word="$2"
    
    [[ "$FORCE" == true ]] && return 0
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                 ⚠️  OPERAÇÃO DESTRUTIVA                           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "$message"
    echo ""
    echo -e "${RED}ESTA AÇÃO NÃO PODE SER DESFEITA!${NC}"
    echo ""
    
    read -r -p "Digite '$confirm_word' para confirmar: " response
    
    if [[ "$response" == "$confirm_word" ]]; then
        return 0
    else
        log_info "Operação cancelada"
        return 1
    fi
}

#===============================================================================
# FUNÇÕES DE DIRETÓRIOS E BACKUP
#===============================================================================

# Inicializa diretórios necessários
init_directories() {
    local dirs=(
        "$BACKUP_DIR"
        "$BACKUP_DIR/credentials"
        "$BACKUP_DIR/deleted_users"
        "$AUDIT_LOG_DIR"
        "$SESSION_LOG_DIR"
        "$TEMP_ACCESS_DIR"
        "$REQUESTS_DIR"
        "$REQUESTS_DIR/approved"
        "$REQUESTS_DIR/denied"
        "$(dirname "$LOG_FILE")"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            chmod 750 "$dir" 2>/dev/null || true
        fi
    done
    
    # Permissões especiais para credenciais
    chmod 700 "$BACKUP_DIR/credentials" 2>/dev/null || true
    
    log_debug "Diretórios inicializados"
}

# Cria backup
create_backup() {
    [[ "$SKIP_BACKUP" == true ]] && return 0
    
    local backup_name
    backup_name="$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log_info "Criando backup: $backup_path"
    
    mkdir -p "$backup_path"
    
    # Backup de arquivos importantes
    [[ -f "$SUDO_FILE" ]] && cp "$SUDO_FILE" "$backup_path/" 2>/dev/null || true
    [[ -f "$DOCKER_WRAPPER_PATH" ]] && cp "$DOCKER_WRAPPER_PATH" "$backup_path/" 2>/dev/null || true
    [[ -f "$CRON_FILE" ]] && cp "$CRON_FILE" "$backup_path/" 2>/dev/null || true
    [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$backup_path/" 2>/dev/null || true
    
    # Salva lista de grupos e membros
    {
        echo "# Backup de grupos - $(_ts)"
        for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
            if group_exists "$group"; then
                echo "GROUP:$group:$(getent group "$group" | cut -d: -f4)"
            fi
        done
    } > "$backup_path/groups.txt"
    
    log_ok "Backup: $backup_path"
    return 0
}

# Lista backups
list_backups() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                        LISTA DE BACKUPS                          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "  Nenhum backup encontrado"
        return 0
    fi
    
    local count=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local name
        name=$(basename "$dir")
        local size
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        
        printf "  %-25s %10s\n" "$name" "$size"
        ((count++))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | head -20)
    
    echo ""
    echo "  Total: $count backups"
    echo "  Diretório: $BACKUP_DIR"
    echo ""
}

# Restaura backup
restore_backup() {
    local backup_name="$1"

    if [[ -z "$backup_name" ]]; then
        log_error "Especifique o nome do backup para restaurar"
        log_error "Use: $SCRIPT_NAME list-backups para ver os disponíveis"
        return 1
    fi

    local backup_path="${BACKUP_DIR}/${backup_name}"

    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup não encontrado: $backup_path"
        return 1
    fi

    log_info "Restaurando backup: $backup_name"

    # Cria backup atual antes de restaurar
    log_info "Criando backup de segurança antes da restauração..."
    create_backup

    local restored=0

    # Restaura sudoers
    local sudoers_file
    sudoers_file=$(find "$backup_path" -maxdepth 1 -name "*.sudoers" -o -name "99-devs-*" 2>/dev/null | head -1)
    if [[ -n "$sudoers_file" && -f "$sudoers_file" ]]; then
        if visudo -c -f "$sudoers_file" &>/dev/null; then
            cp "$sudoers_file" "$SUDO_FILE"
            chmod 440 "$SUDO_FILE"
            log_ok "Sudoers restaurado"
            ((restored++))
        else
            log_warn "Sudoers no backup tem erros de sintaxe, ignorando"
        fi
    fi

    # Restaura config
    if [[ -f "$backup_path/devs_permissions.conf" ]]; then
        cp "$backup_path/devs_permissions.conf" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        log_ok "Configuração restaurada"
        ((restored++))
    fi

    # Restaura docker wrapper
    if [[ -f "$backup_path/docker" ]]; then
        cp "$backup_path/docker" "$DOCKER_WRAPPER_PATH"
        chmod 755 "$DOCKER_WRAPPER_PATH"
        log_ok "Docker wrapper restaurado"
        ((restored++))
    fi

    # Restaura cron
    if [[ -f "$backup_path/devs_permissions_jobs" ]]; then
        cp "$backup_path/devs_permissions_jobs" "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        log_ok "Cron jobs restaurados"
        ((restored++))
    fi

    # Restaura grupos se o arquivo existir
    if [[ -f "$backup_path/groups.txt" ]]; then
        log_info "Informações de grupos disponíveis em: $backup_path/groups.txt"
        log_info "Restauração de membros de grupos requer 'apply' após restaurar config"
    fi

    if [[ $restored -eq 0 ]]; then
        log_warn "Nenhum arquivo encontrado para restaurar no backup"
    else
        audit_log "BACKUP_RESTORED" "root" "backup=$backup_name,files=$restored"
        log_ok "Restauração concluída: $restored arquivo(s) restaurado(s)"
        log_info "Execute '$SCRIPT_NAME apply' para reaplicar as configurações restauradas"
    fi

    return 0
}

#===============================================================================
# GESTÃO DE GRUPOS
#===============================================================================

# Garante que grupo existe
ensure_group_exists() {
    local group="$1"
    
    if group_exists "$group"; then
        log_debug "Grupo existe: $group"
        return 0
    fi
    
    if [[ "$AUTO_CREATE_GROUPS" != true ]]; then
        log_error "Grupo não existe e AUTO_CREATE_GROUPS=false: $group"
        return 1
    fi
    
    log_info "Criando grupo: $group"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "groupadd $group"
        return 0
    fi
    
    if groupadd "$group" 2>/dev/null; then
        audit_log "GROUP_CREATED" "root" "group=$group"
        log_ok "Grupo criado: $group"
        return 0
    else
        log_error "Falha ao criar grupo: $group"
        return 1
    fi
}

#===============================================================================
# GESTÃO DE USUÁRIOS
#===============================================================================

# Cria usuário se não existir
create_user() {
    local user="$1"
    local groups="${2:-$GRUPO_DEV}"
    
    # Valida nome
    if ! validate_username "$user"; then
        return 1
    fi
    
    # Já existe?
    if user_exists "$user"; then
        log_debug "Usuário existe: $user"
        return 0
    fi
    
    if [[ "$AUTO_CREATE_USERS" != true ]]; then
        log_warn "Usuário não existe e AUTO_CREATE_USERS=false: $user"
        return 1
    fi
    
    log_info "Criando usuário: $user"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "useradd -m -s $DEFAULT_SHELL -G $groups -c 'Developer' $user"
        return 0
    fi
    
    # Cria usuário
    if ! useradd -m -s "$DEFAULT_SHELL" -G "$groups" -c "Developer - managed by devs_permissions" "$user" 2>/dev/null; then
        log_error "Falha ao criar usuário: $user"
        return 1
    fi
    
    # Gera senha aleatória
    local password
    password=$(openssl rand -base64 12 2>/dev/null || head -c 12 /dev/urandom | base64)
    
    # Define senha
    echo "$user:$password" | chpasswd 2>/dev/null
    
    # Força troca de senha no primeiro login
    chage -d 0 "$user" 2>/dev/null || true
    
    # Salva credenciais
    local cred_file="${BACKUP_DIR}/credentials/new_user_${user}_$(date +%Y%m%d%H%M%S).cred"
    cat > "$cred_file" << EOF
═══════════════════════════════════════════════════════════
 CREDENCIAIS DE ACESSO - DETRAN-CE
═══════════════════════════════════════════════════════════
 Usuário: $user
 Senha temporária: $password
 
 ⚠️  IMPORTANTE: Troca de senha obrigatória no primeiro login
 
 Data criação: $(_ts)
 Criado por: ${SUDO_USER:-root}
 Ambiente: $ENVIRONMENT
═══════════════════════════════════════════════════════════
EOF
    chmod 600 "$cred_file"
    
    audit_log "USER_CREATED" "root" "user=$user"
    log_ok "Usuário criado: $user"
    log_info "Credenciais: $cred_file"
    
    return 0
}

# Adiciona usuário ao grupo
add_user_to_group() {
    local user="$1"
    local group="$2"
    
    if ! user_exists "$user"; then
        log_warn "Usuário não existe: $user"
        return 1
    fi
    
    if user_in_group "$user" "$group"; then
        log_debug "$user já está em $group"
        return 0
    fi
    
    log_info "Adicionando $user ao grupo $group"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "usermod -aG $group $user"
        return 0
    fi
    
    if usermod -aG "$group" "$user" 2>/dev/null; then
        audit_log "USER_GROUP_ADDED" "root" "user=$user,group=$group"
        log_ok "$user adicionado ao $group"
        return 0
    else
        log_error "Falha ao adicionar $user ao $group"
        return 1
    fi
}

# Remove usuário do grupo
remove_user_from_group() {
    local user="$1"
    local group="$2"
    
    if ! user_exists "$user"; then
        log_debug "Usuário não existe: $user"
        return 0
    fi
    
    if ! user_in_group "$user" "$group"; then
        log_debug "$user não está em $group"
        return 0
    fi
    
    log_info "Removendo $user de $group"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "gpasswd -d $user $group"
        return 0
    fi
    
    if gpasswd -d "$user" "$group" 2>/dev/null; then
        audit_log "USER_GROUP_REMOVED" "root" "user=$user,group=$group"
        log_ok "$user removido de $group"
        return 0
    else
        log_warn "Falha ao remover $user de $group"
        return 1
    fi
}

# Configura .bashrc do usuário
configure_user_bashrc() {
    local user="$1"
    
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    
    [[ -z "$user_home" ]] && return 0
    [[ ! -d "$user_home" ]] && return 0
    
    local bashrc="${user_home}/.bashrc"
    
    # Remove configuração anterior se existir
    if [[ -f "$bashrc" ]]; then
        sed -i '/^# === DEVS PERMISSIONS ===/,/^# === END DEVS ===/d' "$bashrc" 2>/dev/null || true
    fi
    
    # Adiciona nova configuração
    cat >> "$bashrc" << 'EOF'
# === DEVS PERMISSIONS ===
# Configuração adicionada pelo DevOps Permissions Manager
alias docker='sudo docker'
alias docker-compose='sudo docker-compose'
alias dps='sudo docker ps'
alias dlogs='sudo docker logs'
alias dexec='sudo docker exec -it'
alias dinspect='sudo docker inspect'
alias drestart='sudo docker restart'
alias dstats='sudo docker stats'

# Função para logs com highlight
dlf() {
    sudo docker logs -f "$1" 2>&1 | grep --color=auto -E "ERROR|WARN|INFO|DEBUG|$"
}

# Mensagem de boas-vindas
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  DETRAN-CE - Ambiente de Desenvolvimento                         ║"
echo "║  Use 'dps' para listar containers, 'dlogs <container>' para logs ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
# === END DEVS ===
EOF
    
    chown "$user:$user" "$bashrc" 2>/dev/null || true
    log_debug "Bashrc configurado: $user"
}

# Obtém última atividade do usuário
get_user_last_activity() {
    local user="$1"
    
    # Tenta lastlog primeiro
    if command -v lastlog &>/dev/null; then
        local last
        last=$(lastlog -u "$user" 2>/dev/null | tail -1 | awk '{print $4, $5, $6, $7}')
        if [[ -n "$last" ]] && [[ "$last" != *"Never"* ]]; then
            echo "$last"
            return 0
        fi
    fi
    
    # Verifica arquivo de atividade
    local activity_file="${TEMP_ACCESS_DIR}/${user}.lastactivity"
    if [[ -f "$activity_file" ]]; then
        cat "$activity_file"
        return 0
    fi
    
    echo "Nunca"
}

# Atualiza última atividade
update_user_activity() {
    local user="$1"
    
    [[ ! -d "$TEMP_ACCESS_DIR" ]] && mkdir -p "$TEMP_ACCESS_DIR"
    
    echo "$(_ts)" > "${TEMP_ACCESS_DIR}/${user}.lastactivity"
}

#===============================================================================
# GERAÇÃO DE SUDOERS
#===============================================================================

generate_sudoers_content() {
    cat << SUDOERS_HEADER
# ═══════════════════════════════════════════════════════════════════════════════
# Permissões sudo para desenvolvedores
# Gerado por: DevOps Permissions Manager v${SCRIPT_VERSION}
# Equipe: DevOps - DETRAN-CE
# Data: $(_ts)
# Ambiente: ${ENVIRONMENT}
# Restrição por time: ${TEAM_RESTRICTION_ENABLED}
# 
# NÃO EDITE MANUALMENTE - Este arquivo é gerado automaticamente
# ═══════════════════════════════════════════════════════════════════════════════

SUDOERS_HEADER

    # Comandos Docker gerais (todos podem ver)
    cat << 'DOCKER_GENERAL'
# ---------------------------------------------------------------------------
# DOCKER: Comandos de leitura (todos os usuários do grupo devs)
# ---------------------------------------------------------------------------
Cmnd_Alias DOCKER_READ = \
    /usr/bin/docker ps, \
    /usr/bin/docker ps -*, \
    /usr/bin/docker container ls, \
    /usr/bin/docker container ls -*, \
    /usr/bin/docker images, \
    /usr/bin/docker images -*, \
    /usr/bin/docker stats, \
    /usr/bin/docker info, \
    /usr/bin/docker version, \
    /usr/bin/docker network ls, \
    /usr/bin/docker volume ls, \
    /usr/bin/docker compose ps, \
    /usr/bin/docker-compose ps

DOCKER_GENERAL

    # Gera regras de logs
    echo "# ---------------------------------------------------------------------------"
    echo "# LOGS: Leitura de arquivos de log"
    echo "# ---------------------------------------------------------------------------"
    echo "Cmnd_Alias LOG_READ = \\"
    
    local first=true
    for dir in "${LOG_DIRS_ALLOWED[@]}"; do
        [[ ! -d "$dir" ]] && continue
        
        [[ "$first" != true ]] && echo ", \\"
        first=false
        
        echo "    /usr/bin/tail -f ${dir}/*, \\"
        echo "    /usr/bin/tail -f ${dir}/*/*, \\"
        echo "    /usr/bin/tail -n * ${dir}/*, \\"
        echo "    /usr/bin/tail -n * ${dir}/*/*, \\"
        echo "    /usr/bin/cat ${dir}/*, \\"
        echo "    /usr/bin/cat ${dir}/*/*, \\"
        echo "    /usr/bin/less ${dir}/*, \\"
        echo "    /usr/bin/less ${dir}/*/*, \\"
        echo "    /usr/bin/grep * ${dir}/*, \\"
        echo "    /usr/bin/grep * ${dir}/*/*, \\"
        echo "    /usr/bin/ls ${dir}, \\"
        echo -n "    /usr/bin/ls -* ${dir}"
    done
    echo ""
    echo ""

    # Gera regras de webconf
    if [[ ${#WEBCONF_DIRS_ALLOWED[@]} -gt 0 ]]; then
        echo "# ---------------------------------------------------------------------------"
        echo "# WEBCONF: Edição de configurações web"
        echo "# ---------------------------------------------------------------------------"
        
        # Comandos comuns de teste e reload (todos do webconf podem usar)
        echo "Cmnd_Alias WEBCONF_TEST_RELOAD = \\"
        first=true
        for svc in "${WEBCONF_SERVICES_ALLOWED[@]}"; do
            case "$svc" in
                nginx)
                    [[ "$first" != true ]] && echo ", \\"
                    first=false
                    echo "    /usr/sbin/nginx -t, \\"
                    echo "    /usr/bin/systemctl reload nginx, \\"
                    echo -n "    /usr/bin/systemctl status nginx"
                    ;;
                httpd)
                    [[ "$first" != true ]] && echo ", \\"
                    first=false
                    echo "    /usr/sbin/httpd -t, \\"
                    echo "    /usr/sbin/apachectl configtest, \\"
                    echo "    /usr/bin/systemctl reload httpd, \\"
                    echo -n "    /usr/bin/systemctl status httpd"
                    ;;
            esac
        done
        echo ""
        echo ""
        
        # Se restrição por time está DESABILITADA, cria regra global
        if [[ "$TEAM_RESTRICTION_ENABLED" != true ]]; then
            echo "# Restrição por time DESABILITADA - acesso total a configs"
            echo "Cmnd_Alias WEBCONF_EDIT_ALL = \\"
            
            first=true
            for dir in "${WEBCONF_DIRS_ALLOWED[@]}"; do
                [[ ! -d "$dir" ]] && continue
                
                [[ "$first" != true ]] && echo ", \\"
                first=false
                
                echo "    /usr/bin/sudoedit ${dir}/*.conf, \\"
                echo "    /usr/bin/cat ${dir}/*.conf, \\"
                echo "    /usr/bin/less ${dir}/*.conf, \\"
                echo "    /usr/bin/ls ${dir}, \\"
                echo -n "    /usr/bin/ls -* ${dir}"
            done
            echo ""
            echo ""
        fi
    fi

    # Permissões básicas por grupo
    cat << BASIC_PERMS
# ---------------------------------------------------------------------------
# PERMISSÕES BÁSICAS POR GRUPO
# ---------------------------------------------------------------------------
%${GRUPO_DEV} ALL=(root) NOPASSWD: DOCKER_READ
%${GRUPO_DEV} ALL=(root) NOPASSWD: LOG_READ
BASIC_PERMS

    # Webconf - depende se tem restrição por time
    if [[ ${#WEBCONF_DIRS_ALLOWED[@]} -gt 0 ]]; then
        echo "%${GRUPO_DEV_WEBCONF} ALL=(root) NOPASSWD: WEBCONF_TEST_RELOAD"
        
        if [[ "$TEAM_RESTRICTION_ENABLED" != true ]]; then
            echo "%${GRUPO_DEV_WEBCONF} ALL=(root) NOPASSWD: WEBCONF_EDIT_ALL"
        fi
    fi
    echo ""

    # Se restrição por time está habilitada
    if [[ "$TEAM_RESTRICTION_ENABLED" == true ]] && [[ ${#TEAMS[@]} -gt 0 ]]; then
        echo "# ═══════════════════════════════════════════════════════════════════════════════"
        echo "# REGRAS POR TIME - Acesso restrito a containers específicos"
        echo "# ═══════════════════════════════════════════════════════════════════════════════"
        echo ""
        
        for team in "${TEAMS[@]}"; do
            local users_var="TEAM_${team}_USERS"
            local containers_var="TEAM_${team}_CONTAINERS"
            
            # Verifica se as variáveis existem
            if ! declare -p "$users_var" &>/dev/null; then
                continue
            fi
            if ! declare -p "$containers_var" &>/dev/null; then
                continue
            fi
            
            # Obtém arrays
            local -a team_users team_containers
            eval "team_users=(\"\${${users_var}[@]}\")"
            eval "team_containers=(\"\${${containers_var}[@]}\")"
            
            [[ ${#team_users[@]} -eq 0 ]] && continue
            [[ ${#team_containers[@]} -eq 0 ]] && continue
            
            echo "# ---------------------------------------------------------------------------"
            echo "# TIME: ${team}"
            echo "# Containers: ${team_containers[*]}"
            echo "# Usuários: ${team_users[*]}"
            echo "# ---------------------------------------------------------------------------"
            echo ""
            
            # Alias para comandos do time
            local alias_read="DOCKER_TEAM_${team}"
            local alias_exec="DOCKER_EXEC_TEAM_${team}"
            
            # Comandos de leitura por container
            echo "Cmnd_Alias ${alias_read} = \\"
            first=true
            for container in "${team_containers[@]}"; do
                # Usa padrões configuráveis se existirem, senão usa defaults
                if [[ ${#DOCKER_LOGS_PATTERNS[@]} -gt 0 ]]; then
                    # Padrões de logs do config
                    for pattern in "${DOCKER_LOGS_PATTERNS[@]}"; do
                        local cmd="${pattern//\{CONTAINER\}/${container}}"
                        [[ "$first" != true ]] && echo ", \\"
                        first=false
                        echo -n "    /usr/bin/docker ${cmd}"
                    done
                else
                    # Padrões default (fallback)
                    [[ "$first" != true ]] && echo ", \\"
                    first=false
                    echo "    /usr/bin/docker logs ${container}, \\"
                    echo "    /usr/bin/docker logs -f ${container}, \\"
                    echo "    /usr/bin/docker logs --follow ${container}, \\"
                    echo "    /usr/bin/docker logs --tail * ${container}, \\"
                    echo "    /usr/bin/docker logs -n * ${container}, \\"
                    echo "    /usr/bin/docker logs -f --tail * ${container}, \\"
                    echo "    /usr/bin/docker logs -fn* ${container}, \\"
                    echo -n "    /usr/bin/docker logs --since * ${container}"
                fi
                
                # Outros comandos de container
                if [[ ${#DOCKER_CONTAINER_PATTERNS[@]} -gt 0 ]]; then
                    for pattern in "${DOCKER_CONTAINER_PATTERNS[@]}"; do
                        local cmd="${pattern//\{CONTAINER\}/${container}}"
                        echo ", \\"
                        echo -n "    /usr/bin/docker ${cmd}"
                    done
                else
                    # Padrões default (fallback)
                    echo ", \\"
                    echo "    /usr/bin/docker inspect ${container}, \\"
                    echo "    /usr/bin/docker top ${container}, \\"
                    echo "    /usr/bin/docker stats ${container}, \\"
                    echo "    /usr/bin/docker stats --no-stream ${container}, \\"
                    echo "    /usr/bin/docker restart ${container}, \\"
                    echo "    /usr/bin/docker stop ${container}, \\"
                    echo -n "    /usr/bin/docker start ${container}"
                fi
            done
            echo ""
            echo ""
            
            # Comandos exec por container
            echo "Cmnd_Alias ${alias_exec} = \\"
            first=true
            for container in "${team_containers[@]}"; do
                for cmd in "${DOCKER_EXEC_COMMANDS_ALLOWED[@]}"; do
                    [[ "$first" != true ]] && echo ", \\"
                    first=false
                    echo "    /usr/bin/docker exec -it ${container} ${cmd}, \\"
                    echo "    /usr/bin/docker exec -ti ${container} ${cmd}, \\"
                    echo -n "    /usr/bin/docker exec ${container} ${cmd}"
                done
            done
            echo ""
            echo ""
            
            # ══════════════════════════════════════════════════════════════════════
            # WEBCONF POR TIME - Padrões de arquivos .conf permitidos
            # ══════════════════════════════════════════════════════════════════════
            # Verifica se existe configuração de webconf para este time
            local webconf_var="TEAM_${team}_WEBCONF_PATTERNS"
            local has_webconf_patterns=false
            local -a team_webconf_patterns=()
            
            if declare -p "$webconf_var" &>/dev/null; then
                eval "team_webconf_patterns=(\"\${${webconf_var}[@]}\")"
                [[ ${#team_webconf_patterns[@]} -gt 0 ]] && has_webconf_patterns=true
            fi
            
            local alias_webconf="WEBCONF_TEAM_${team}"
            
            echo "# Webconf do time: padrões de arquivos permitidos"
            echo "Cmnd_Alias ${alias_webconf} = \\"
            first=true
            
            for dir in "${WEBCONF_DIRS_ALLOWED[@]}"; do
                [[ ! -d "$dir" ]] && continue
                
                if [[ "$has_webconf_patterns" == true ]]; then
                    # Usa padrões definidos explicitamente
                    for pattern in "${team_webconf_patterns[@]}"; do
                        # Padrão já vem no formato correto: veiculo*, admin*, etc
                        local file_pattern="${pattern}"
                        [[ "$file_pattern" != *".conf" ]] && file_pattern="${file_pattern}.conf"
                        
                        [[ "$first" != true ]] && echo ", \\"
                        first=false
                        
                        echo "    /usr/bin/vim ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/vi ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/nano ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/cat ${dir}/${file_pattern}, \\"
                        echo -n "    /usr/bin/less ${dir}/${file_pattern}"
                    done
                else
                    # Deriva padrões dos containers (fallback)
                    for container_pattern in "${team_containers[@]}"; do
                        # Converte padrão de container para padrão de arquivo
                        # Ex: veiculo-* -> veiculo*.conf
                        local file_pattern="${container_pattern//-/}"  # Remove hífens
                        file_pattern="${file_pattern%\*}"              # Remove * do final
                        file_pattern="${file_pattern}*.conf"           # Adiciona *.conf
                        
                        [[ "$first" != true ]] && echo ", \\"
                        first=false
                        
                        echo "    /usr/bin/vim ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/vi ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/nano ${dir}/${file_pattern}, \\"
                        echo "    /usr/bin/cat ${dir}/${file_pattern}, \\"
                        echo -n "    /usr/bin/less ${dir}/${file_pattern}"
                    done
                fi
            done
            
            # Adiciona permissão de listar diretório (sem restrição de arquivo)
            for dir in "${WEBCONF_DIRS_ALLOWED[@]}"; do
                [[ ! -d "$dir" ]] && continue
                echo ", \\"
                echo "    /usr/bin/ls ${dir}, \\"
                echo -n "    /usr/bin/ls -* ${dir}"
            done
            echo ""
            echo ""
            
            # Permissões por usuário
            for user in "${team_users[@]}"; do
                echo "# Usuário: ${user} (time: ${team})"
                echo "${user} ALL=(root) NOPASSWD: ${alias_read}"
                
                # Verifica se tem permissão exec
                local has_exec=false
                for exec_user in "${USUARIOS_EXEC[@]}"; do
                    if [[ "$exec_user" == "$user" ]]; then
                        has_exec=true
                        break
                    fi
                done
                
                if [[ "$has_exec" == true ]]; then
                    echo "${user} ALL=(root) NOPASSWD: ${alias_exec}"
                fi
                
                # Verifica se tem permissão webconf
                local has_webconf=false
                for webconf_user in "${USUARIOS_WEBCONF[@]}"; do
                    if [[ "$webconf_user" == "$user" ]]; then
                        has_webconf=true
                        break
                    fi
                done
                
                if [[ "$has_webconf" == true ]]; then
                    echo "${user} ALL=(root) NOPASSWD: ${alias_webconf}"
                fi
                echo ""
            done
        done
    fi

    # Usuários sem time (acesso a todos os containers)
    local -a users_without_team=()
    local all_team_users=""
    
    # Coleta todos os usuários que estão em times
    for team in "${TEAMS[@]}"; do
        local users_var="TEAM_${team}_USERS"
        if declare -p "$users_var" &>/dev/null; then
            eval "all_team_users+=\" \${${users_var}[*]}\""
        fi
    done
    
    # Identifica usuários sem time
    local -a all_config_users=("${USUARIOS[@]}" "${USUARIOS_EXEC[@]}")
    for user in "${all_config_users[@]}"; do
        [[ -z "$user" ]] && continue
        
        # Verifica se está em algum time
        local in_team=false
        if [[ "$all_team_users" == *"$user"* ]]; then
            in_team=true
        fi
        
        if [[ "$in_team" == false ]]; then
            # Verifica se já não está na lista
            local already_listed=false
            for u in "${users_without_team[@]}"; do
                [[ "$u" == "$user" ]] && already_listed=true && break
            done
            
            [[ "$already_listed" == false ]] && users_without_team+=("$user")
        fi
    done
    
    # Gera regras para usuários sem time
    if [[ ${#users_without_team[@]} -gt 0 ]] || [[ "$TEAM_RESTRICTION_ENABLED" != true ]]; then
        echo "# ═══════════════════════════════════════════════════════════════════════════════"
        echo "# ACESSO COMPLETO - Usuários sem restrição de time"
        echo "# ═══════════════════════════════════════════════════════════════════════════════"
        echo ""
        
        # Alias para todos os containers
        echo "Cmnd_Alias DOCKER_ALL = \\"
        echo "    /usr/bin/docker logs *, \\"
        echo "    /usr/bin/docker logs -f *, \\"
        echo "    /usr/bin/docker logs --tail * *, \\"
        echo "    /usr/bin/docker inspect *, \\"
        echo "    /usr/bin/docker top *, \\"
        echo "    /usr/bin/docker stats *, \\"
        echo "    /usr/bin/docker restart *, \\"
        echo "    /usr/bin/docker stop *, \\"
        echo "    /usr/bin/docker start *"
        echo ""
        
        echo "Cmnd_Alias DOCKER_EXEC_ALL = \\"
        first=true
        for cmd in "${DOCKER_EXEC_COMMANDS_ALLOWED[@]}"; do
            [[ "$first" != true ]] && echo ", \\"
            first=false
            echo "    /usr/bin/docker exec -it * ${cmd}, \\"
            echo "    /usr/bin/docker exec -ti * ${cmd}, \\"
            echo -n "    /usr/bin/docker exec * ${cmd}"
        done
        echo ""
        echo ""
        
        # Webconf total para usuários sem time
        if [[ ${#WEBCONF_DIRS_ALLOWED[@]} -gt 0 ]] && [[ "$TEAM_RESTRICTION_ENABLED" == true ]]; then
            echo "# Webconf total para usuários sem restrição de time"
            echo "Cmnd_Alias WEBCONF_EDIT_FULL = \\"
            first=true
            for dir in "${WEBCONF_DIRS_ALLOWED[@]}"; do
                [[ ! -d "$dir" ]] && continue
                
                [[ "$first" != true ]] && echo ", \\"
                first=false
                
                echo "    /usr/bin/sudoedit ${dir}/*.conf, \\"
                echo "    /usr/bin/cat ${dir}/*.conf, \\"
                echo "    /usr/bin/less ${dir}/*.conf, \\"
                echo "    /usr/bin/ls ${dir}, \\"
                echo -n "    /usr/bin/ls -* ${dir}"
            done
            echo ""
            echo ""
        fi
        
        if [[ "$TEAM_RESTRICTION_ENABLED" != true ]]; then
            # Todos os usuários têm acesso
            echo "# Restrição por time DESABILITADA - grupo tem acesso total"
            echo "%${GRUPO_DEV} ALL=(root) NOPASSWD: DOCKER_ALL"
            echo "%${GRUPO_DEV_EXEC} ALL=(root) NOPASSWD: DOCKER_EXEC_ALL"
        else
            # Apenas usuários sem time
            for user in "${users_without_team[@]}"; do
                echo "# Usuário: ${user} (sem time - acesso total)"
                echo "${user} ALL=(root) NOPASSWD: DOCKER_ALL"
                
                # Verifica se tem exec
                for exec_user in "${USUARIOS_EXEC[@]}"; do
                    if [[ "$exec_user" == "$user" ]]; then
                        echo "${user} ALL=(root) NOPASSWD: DOCKER_EXEC_ALL"
                        break
                    fi
                done
                
                # Verifica se tem webconf
                for webconf_user in "${USUARIOS_WEBCONF[@]}"; do
                    if [[ "$webconf_user" == "$user" ]]; then
                        echo "${user} ALL=(root) NOPASSWD: WEBCONF_EDIT_FULL"
                        break
                    fi
                done
                echo ""
            done
        fi
    fi
    
    echo ""
    echo "# ═══════════════════════════════════════════════════════════════════════════════"
    echo "# FIM DAS REGRAS"
    echo "# ═══════════════════════════════════════════════════════════════════════════════"
}

# Configura sudoers
configure_sudoers() {
    log_info "Configurando sudoers..."
    
    local temp_file
    temp_file=$(mktemp)
    
    # Gera conteúdo
    generate_sudoers_content > "$temp_file"
    
    # Valida sintaxe
    if ! visudo -c -f "$temp_file" &>/dev/null; then
        log_error "Erro de sintaxe no sudoers gerado"
        cat "$temp_file" >&2
        rm -f "$temp_file"
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Sudoers seria instalado em: $SUDO_FILE"
        rm -f "$temp_file"
        return 0
    fi
    
    # Instala
    cp "$temp_file" "$SUDO_FILE"
    chmod 440 "$SUDO_FILE"
    rm -f "$temp_file"
    
    # Valida instalação
    if visudo -c &>/dev/null; then
        log_ok "Sudoers configurado"
        return 0
    else
        log_error "Erro na validação final do sudoers"
        return 1
    fi
}

# Remove sudoers antigos
cleanup_old_sudoers() {
    log_info "Limpando sudoers antigos..."
    
    local old_files=(
        "/etc/sudoers.d/devs_docker_limited"
        "/etc/sudoers.d/devs_access_rules"
        "/etc/sudoers.d/devs_logs_access"
    )
    
    for file in "${old_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_debug "Removendo: $file"
            rm -f "$file" 2>/dev/null || true
        fi
    done
    
    log_ok "Limpeza concluída"
}

#===============================================================================
# DOCKER WRAPPER E ACLS
#===============================================================================

# Cria wrapper Docker com auditoria
create_docker_wrapper() {
    log_info "Criando wrapper Docker com auditoria..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Docker wrapper seria criado em: $DOCKER_WRAPPER_PATH"
        return 0
    fi
    
    cat > "$DOCKER_WRAPPER_PATH" << 'WRAPPER'
#!/usr/bin/env bash
#===============================================================================
# Docker Wrapper com Auditoria
# Gerado por DevOps Permissions Manager
#===============================================================================

REAL_DOCKER="/usr/bin/docker"
AUDIT_LOG="/var/log/devs_audit/docker_audit.log"
SESSION_LOG_DIR="/var/log/devs_audit/sessions"

# Comandos bloqueados
BLOCKED_PATTERNS=(
    "rm -rf /"
    "rm -rf /*"
    "dd if=/dev"
    "mkfs"
    "> /dev/sd"
    "chmod 777 /"
    "chmod -R 777 /"
)

# Função de log
log_audit() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-${USER:-unknown}}"
    local cmd="$*"
    local ip="local"
    
    [[ -n "${SSH_CLIENT:-}" ]] && ip="${SSH_CLIENT%% *}"
    
    mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null
    echo "{\"timestamp\":\"${timestamp}\",\"user\":\"${user}\",\"command\":\"docker ${cmd}\",\"ip\":\"${ip}\"}" >> "$AUDIT_LOG"
}

# Log de sessão
log_session() {
    local user="${SUDO_USER:-${USER:-unknown}}"
    local container="$1"
    local cmd="$2"
    
    mkdir -p "$SESSION_LOG_DIR" 2>/dev/null
    local session_file="${SESSION_LOG_DIR}/${user}_$(date '+%Y-%m-%d').log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] container=$container command=\"$cmd\"" >> "$session_file"
}

# Verifica comandos bloqueados
check_blocked() {
    local full_cmd="$*"
    
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
        if [[ "$full_cmd" == *"$pattern"* ]]; then
            echo "[BLOCKED] Comando bloqueado por segurança: $pattern" >&2
            log_audit "BLOCKED" "$full_cmd"
            exit 1
        fi
    done
}

# Log da ação
log_audit "$@"

# Verifica comandos bloqueados
check_blocked "$@"

# Se é exec, faz log de sessão (extrai info sem consumir $@)
if [[ "${1:-}" == "exec" ]]; then
    _container=""
    _exec_cmd=""
    _skip_next=false
    for _arg in "${@:2}"; do
        if [[ "$_skip_next" == true ]]; then
            _skip_next=false
            continue
        fi
        case "$_arg" in
            -it|-ti|-i|-t|--interactive|--tty) ;;
            -u|--user|-w|--workdir|-e|--env) _skip_next=true ;;
            -*) ;;
            *)
                if [[ -z "$_container" ]]; then
                    _container="$_arg"
                else
                    _exec_cmd="$_exec_cmd $_arg"
                fi
                ;;
        esac
    done
    log_session "$_container" "$_exec_cmd"
fi

# Executa comando real (argumentos originais intactos)
exec "$REAL_DOCKER" "$@"
WRAPPER
    
    chmod 755 "$DOCKER_WRAPPER_PATH"
    log_ok "Wrapper criado"
}

# Configura ACLs nos diretórios de log
configure_acls() {
    log_info "Configurando ACLs..."
    
    local configured=0
    
    # ACLs para diretórios de LOG (leitura apenas)
    log_info "Configurando ACLs de leitura para logs..."
    for dir in "${LOG_DIRS_ALLOWED[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Não existe: $dir"
            continue
        fi
        
        log_debug "ACL (leitura): $dir"
        
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "setfacl -R -m g:${GRUPO_DEV}:rx $dir"
            continue
        fi
        
        # Aplica ACL recursivamente - apenas leitura
        setfacl -R -m "g:${GRUPO_DEV}:rx" "$dir" 2>/dev/null || true
        setfacl -R -d -m "g:${GRUPO_DEV}:rx" "$dir" 2>/dev/null || true
        
        ((configured++))
    done
    
    # ACLs para diretórios de WEBCONF (leitura E escrita para devs_webconf)
    log_info "Configurando ACLs de escrita para webconf..."
    for dir in "${WEBCONF_DIRS_ALLOWED[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Não existe: $dir"
            continue
        fi
        
        log_debug "ACL (escrita): $dir para $GRUPO_DEV_WEBCONF"
        
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "setfacl -R -m g:${GRUPO_DEV_WEBCONF}:rwx $dir"
            continue
        fi
        
        # Aplica ACL recursivamente - leitura e escrita para webconf
        # Permissão rwx no diretório para poder criar arquivos
        setfacl -R -m "g:${GRUPO_DEV_WEBCONF}:rwx" "$dir" 2>/dev/null || true
        # ACL default para novos arquivos criados
        setfacl -R -d -m "g:${GRUPO_DEV_WEBCONF}:rwx" "$dir" 2>/dev/null || true
        
        # Também dá permissão de leitura para o grupo básico
        setfacl -R -m "g:${GRUPO_DEV}:rx" "$dir" 2>/dev/null || true
        setfacl -R -d -m "g:${GRUPO_DEV}:rx" "$dir" 2>/dev/null || true
        
        ((configured++))
        log_ok "ACL webconf aplicada: $dir"
    done
    
    log_ok "ACLs configuradas: $configured diretórios"
}

#===============================================================================
# CRON JOBS E LOGROTATE
#===============================================================================

# Configura cron jobs
setup_cron_jobs() {
    log_info "Configurando cron jobs..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Cron jobs seriam configurados em: $CRON_FILE"
        return 0
    fi
    
    # Resolve o path absoluto real do script (funciona mesmo via symlink)
    local real_script_path
    real_script_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${SCRIPT_DIR}/${SCRIPT_NAME}")

    cat > "$CRON_FILE" << EOF
# DevOps Permissions Manager - Cron Jobs
# Gerado automaticamente em: $(_ts)

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Limpeza de acessos temporários expirados (a cada 15 min)
*/15 * * * * root ${real_script_path} cleanup >/dev/null 2>&1

# Relatório semanal (segunda-feira às 8h)
0 8 * * 1 root ${real_script_path} send-report >/dev/null 2>&1

# Health check diário (6h)
0 6 * * * root ${real_script_path} health-check >/dev/null 2>&1

# Rotação de logs de sessão (domingo 3h - mantém 90 dias)
0 3 * * 0 root find ${SESSION_LOG_DIR} -name "*.log" -mtime +90 -delete 2>/dev/null
EOF
    
    chmod 644 "$CRON_FILE"
    log_ok "Cron jobs configurados"
}

# Configura logrotate
setup_logrotate() {
    log_info "Configurando logrotate..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Logrotate seria configurado"
        return 0
    fi
    
    cat > "/etc/logrotate.d/devs_permissions" << EOF
# DevOps Permissions Manager - Logrotate
# Gerado automaticamente

${AUDIT_LOG_FILE} {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}

${LOG_FILE} {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}

${SESSION_LOG_DIR}/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF
    
    log_ok "Logrotate configurado"
}

#===============================================================================
# ACESSO TEMPORÁRIO
#===============================================================================

# Concede acesso temporário
grant_temp_access() {
    local user="$1"
    local hours="$2"
    local reason="${3:-}"
    
    if ! user_exists "$user"; then
        log_error "Usuário não existe: $user"
        return 1
    fi
    
    # Verifica limite de horas
    local max_hours
    max_hours=$(get_max_temp_hours)
    
    if [[ $hours -gt $max_hours ]]; then
        log_warn "Horas solicitadas ($hours) excedem máximo ($max_hours) para ambiente $ENVIRONMENT"
        hours=$max_hours
    fi
    
    # Calcula expiração
    local expiry
    expiry=$(date -d "+${hours} hours" +%s)
    local expiry_date
    expiry_date=$(date -d "@$expiry" '+%Y-%m-%d %H:%M:%S')
    
    log_info "Concedendo acesso temporário: $user por ${hours}h"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Acesso temporário seria concedido até $expiry_date"
        return 0
    fi
    
    # Adiciona ao grupo exec
    add_user_to_group "$user" "$GRUPO_DEV_EXEC"
    
    # Salva expiração
    mkdir -p "$TEMP_ACCESS_DIR"
    echo "$expiry" > "${TEMP_ACCESS_DIR}/${user}.expiry"
    echo "$reason" > "${TEMP_ACCESS_DIR}/${user}.reason"
    
    audit_log "TEMP_ACCESS_GRANTED" "$user" "hours=$hours,expires=$expiry_date,reason=$reason"
    
    notify_temp_access "$user" "$hours" "granted"
    
    log_ok "Acesso concedido até: $expiry_date"
    return 0
}

# Revoga acesso temporário
revoke_temp_access() {
    local user="$1"
    local reason="${2:-manual}"
    
    log_info "Revogando acesso temporário: $user"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Acesso temporário seria revogado"
        return 0
    fi
    
    # Remove do grupo exec
    remove_user_from_group "$user" "$GRUPO_DEV_EXEC"
    
    # Remove arquivos
    rm -f "${TEMP_ACCESS_DIR}/${user}.expiry" 2>/dev/null
    rm -f "${TEMP_ACCESS_DIR}/${user}.reason" 2>/dev/null
    
    audit_log "TEMP_ACCESS_REVOKED" "$user" "reason=$reason"
    
    notify_temp_access "$user" "0" "revoked"
    
    log_ok "Acesso revogado: $user"
    return 0
}

# Limpa acessos expirados
cleanup_expired_access() {
    log_debug "Verificando acessos expirados..."
    
    [[ ! -d "$TEMP_ACCESS_DIR" ]] && return 0
    
    local now
    now=$(date +%s)
    local cleaned=0
    
    for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
        [[ ! -f "$expiry_file" ]] && continue
        
        local user
        user=$(basename "$expiry_file" .expiry)
        local expiry
        expiry=$(cat "$expiry_file" 2>/dev/null || echo "0")
        
        if [[ $now -gt $expiry ]]; then
            log_info "Acesso expirado: $user"
            revoke_temp_access "$user" "expired"
            ((cleaned++))
        fi
    done
    
    [[ $cleaned -gt 0 ]] && log_ok "Acessos expirados removidos: $cleaned"
    return 0
}

# Lista usuários inativos
list_inactive_users() {
    local days="${1:-$INACTIVITY_DAYS}"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              USUÁRIOS INATIVOS (> $days dias)                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    local threshold
    threshold=$(date -d "-${days} days" +%s)
    local count=0
    
    # Coleta todos os usuários únicos dos grupos
    local all_members=""
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC"; do
        group_exists "$group" || continue
        local members
        members=$(getent group "$group" | cut -d: -f4)
        [[ -n "$members" ]] && all_members="${all_members:+${all_members},}${members}"
    done

    # Deduplica
    local unique_users
    unique_users=$(echo "$all_members" | tr ',' '\n' | sort -u | grep -v '^$')

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue

        local last_activity
        last_activity=$(get_user_last_activity "$user")

        # Tenta converter para timestamp
        local activity_ts=0
        if [[ "$last_activity" != "Nunca" ]]; then
            activity_ts=$(date -d "$last_activity" +%s 2>/dev/null || echo "0")
        fi

        if [[ $activity_ts -lt $threshold ]]; then
            printf "  %-20s  Última atividade: %s\n" "$user" "$last_activity"
            ((count++))
        fi
    done <<< "$unique_users"
    
    echo ""
    echo "  Total: $count usuários inativos"
    echo ""
}

# Revoga usuários inativos
# PATCH v5.0.1: Não revoga usuários permanentes (USUARIOS_EXEC) nem "Nunca"
revoke_inactive_users() {
    local days="${1:-$INACTIVITY_DAYS}"
    
    [[ "$AUTO_REVOKE_INACTIVE" != true ]] && return 0
    
    log_info "Verificando usuários inativos (> $days dias)..."
    
    local threshold
    threshold=$(date -d "-${days} days" +%s)
    local revoked=0
    local skipped_permanent=0
    local skipped_no_data=0
    
    # Verifica usuários com acesso exec
    if group_exists "$GRUPO_DEV_EXEC"; then
        local members
        members=$(getent group "$GRUPO_DEV_EXEC" | cut -d: -f4)
        
        IFS=',' read -ra users <<< "$members"
        for user in "${users[@]}"; do
            [[ -z "$user" ]] && continue
            
            # PATCH: Pula usuários permanentes (listados em USUARIOS_EXEC)
            local is_permanent=false
            for perm_user in "${USUARIOS_EXEC[@]}"; do
                if [[ "$perm_user" == "$user" ]]; then
                    is_permanent=true
                    break
                fi
            done
            if [[ "$is_permanent" == true ]]; then
                log_debug "Usuário permanente (USUARIOS_EXEC), ignorando: $user"
                ((skipped_permanent++))
                continue
            fi
            
            local last_activity
            last_activity=$(get_user_last_activity "$user")
            
            # PATCH: "Nunca" = sem dados de atividade, NÃO significa inativo
            if [[ "$last_activity" == "Nunca" ]]; then
                log_debug "Sem dados de atividade, ignorando: $user"
                ((skipped_no_data++))
                continue
            fi
            
            local activity_ts=0
            activity_ts=$(date -d "$last_activity" +%s 2>/dev/null || echo "0")
            
            # Só revoga se tem data válida E está inativo há mais de N dias
            if [[ $activity_ts -gt 0 ]] && [[ $activity_ts -lt $threshold ]]; then
                log_info "Usuário inativo: $user (última atividade: $last_activity)"
                
                if [[ "$DRY_RUN" != true ]]; then
                    remove_user_from_group "$user" "$GRUPO_DEV_EXEC"
                    audit_log "INACTIVE_USER_REVOKED" "root" "user=$user,last_activity=$last_activity"
                fi
                
                ((revoked++))
            fi
        done
    fi
    
    log_debug "Revogação: $revoked removidos, $skipped_permanent permanentes ignorados, $skipped_no_data sem dados ignorados"
    [[ $revoked -gt 0 ]] && log_ok "Usuários inativos revogados: $revoked"
    return 0
}

#===============================================================================
# SOLICITAÇÕES (SELF-SERVICE)
#===============================================================================

# Gera ID de solicitação
generate_request_id() {
    echo "REQ-$(date '+%Y%m%d')-$(printf '%03d' $((RANDOM % 1000)))"
}

# Cria solicitação
create_request() {
    local user="$1"
    local hours="$2"
    local reason="$3"
    
    if ! user_exists "$user"; then
        log_error "Usuário não existe: $user"
        return 1
    fi
    
    if [[ -z "$reason" ]]; then
        log_error "Motivo é obrigatório para solicitações"
        return 1
    fi
    
    local request_id
    request_id=$(generate_request_id)
    
    log_info "Criando solicitação: $request_id"
    
    mkdir -p "$REQUESTS_DIR"
    
    # Escape JSON special characters in reason
    local safe_reason="${reason//\\/\\\\}"
    safe_reason="${safe_reason//\"/\\\"}"
    safe_reason="${safe_reason//$'\n'/\\n}"
    safe_reason="${safe_reason//$'\t'/\\t}"

    # Validate hours is numeric
    if ! [[ "$hours" =~ ^[0-9]+$ ]]; then
        log_error "Horas deve ser um número: $hours"
        return 1
    fi

    cat > "${REQUESTS_DIR}/${request_id}.json" << EOF
{
    "request_id": "$request_id",
    "user": "$user",
    "hours": $hours,
    "reason": "$safe_reason",
    "status": "pending",
    "timestamp": "$(_ts)",
    "created_by": "${SUDO_USER:-$user}",
    "environment": "$ENVIRONMENT"
}
EOF
    
    audit_log "REQUEST_CREATED" "$user" "request_id=$request_id,hours=$hours"
    
    notify_request "$user" "$request_id" "$hours" "$reason"
    
    log_ok "Solicitação criada: $request_id"
    echo ""
    echo "  ID: $request_id"
    echo "  Aguardando aprovação"
    echo ""
    
    return 0
}

# Aprova solicitação
approve_request() {
    local request_id="$1"
    local approver="${2:-${SUDO_USER:-root}}"
    
    local request_file="${REQUESTS_DIR}/${request_id}.json"
    
    if [[ ! -f "$request_file" ]]; then
        log_error "Solicitação não encontrada: $request_id"
        return 1
    fi
    
    # Lê dados da solicitação
    local user hours
    user=$(grep -o '"user": *"[^"]*"' "$request_file" | cut -d'"' -f4)
    hours=$(grep -o '"hours": *[0-9]*' "$request_file" | grep -o '[0-9]*')
    
    log_info "Aprovando solicitação: $request_id"
    
    # Concede acesso
    grant_temp_access "$user" "$hours" "request_id=$request_id,approver=$approver"
    
    # Move para aprovados
    mkdir -p "${REQUESTS_DIR}/approved"
    mv "$request_file" "${REQUESTS_DIR}/approved/"
    
    audit_log "REQUEST_APPROVED" "$approver" "request_id=$request_id,user=$user"
    
    log_ok "Solicitação aprovada: $request_id"
    return 0
}

# Nega solicitação
deny_request() {
    local request_id="$1"
    local reason="${2:-}"
    local denier="${SUDO_USER:-root}"
    
    local request_file="${REQUESTS_DIR}/${request_id}.json"
    
    if [[ ! -f "$request_file" ]]; then
        log_error "Solicitação não encontrada: $request_id"
        return 1
    fi
    
    log_info "Negando solicitação: $request_id"
    
    # Move para negados
    mkdir -p "${REQUESTS_DIR}/denied"
    mv "$request_file" "${REQUESTS_DIR}/denied/"
    
    audit_log "REQUEST_DENIED" "$denier" "request_id=$request_id,reason=$reason"
    
    log_ok "Solicitação negada: $request_id"
    return 0
}

# Lista solicitações pendentes
list_requests() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                   SOLICITAÇÕES PENDENTES                         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ ! -d "$REQUESTS_DIR" ]]; then
        echo "  Nenhuma solicitação pendente"
        echo ""
        return 0
    fi
    
    local count=0
    
    for request_file in "$REQUESTS_DIR"/*.json; do
        [[ ! -f "$request_file" ]] && continue
        
        local id user hours reason created
        id=$(grep -o '"id": *"[^"]*"' "$request_file" | cut -d'"' -f4)
        user=$(grep -o '"user": *"[^"]*"' "$request_file" | cut -d'"' -f4)
        hours=$(grep -o '"hours": *[0-9]*' "$request_file" | grep -o '[0-9]*')
        reason=$(grep -o '"reason": *"[^"]*"' "$request_file" | cut -d'"' -f4)
        created=$(grep -o '"created_at": *"[^"]*"' "$request_file" | cut -d'"' -f4)
        
        echo "  ┌─────────────────────────────────────────────────────"
        echo "  │ ID: $id"
        echo "  │ Usuário: $user"
        echo "  │ Horas: $hours"
        echo "  │ Motivo: $reason"
        echo "  │ Criado: $created"
        echo "  │"
        echo "  │ Para aprovar: $SCRIPT_NAME approve --request-id $id"
        echo "  │ Para negar:   $SCRIPT_NAME deny --request-id $id"
        echo "  └─────────────────────────────────────────────────────"
        echo ""
        
        ((count++))
    done
    
    if [[ $count -eq 0 ]]; then
        echo "  Nenhuma solicitação pendente"
    else
        echo "  Total: $count solicitações"
    fi
    echo ""
}

#===============================================================================
# RELATÓRIOS E AUDITORIA
#===============================================================================

# Gera relatório de auditoria
generate_audit_report() {
    local days="${1:-7}"
    local user_filter="${2:-}"
    local format="${3:-text}"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              RELATÓRIO DE AUDITORIA (últimos $days dias)         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        echo "  Nenhum registro de auditoria encontrado"
        return 0
    fi
    
    local since
    since=$(date -d "-${days} days" '+%Y-%m-%d')
    
    echo "  Período: $since até $(_date)"
    echo ""
    
    # Estatísticas
    local total_events=0
    local blocked_events=0
    local temp_grants=0
    local user_creates=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # Extrai timestamp
        local ts
        ts=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
        local ts_date="${ts%% *}"
        
        [[ "$ts_date" < "$since" ]] && continue
        
        # Filtra por usuário se especificado
        if [[ -n "$user_filter" ]]; then
            local event_user
            event_user=$(echo "$line" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)
            [[ "$event_user" != "$user_filter" ]] && continue
        fi
        
        ((total_events++))
        
        # Conta por tipo
        [[ "$line" == *"BLOCKED"* ]] && ((blocked_events++))
        [[ "$line" == *"TEMP_ACCESS_GRANTED"* ]] && ((temp_grants++))
        [[ "$line" == *"USER_CREATED"* ]] && ((user_creates++))
        
    done < "$AUDIT_LOG_FILE"
    
    echo "  Estatísticas:"
    echo "    Total de eventos: $total_events"
    echo "    Ações bloqueadas: $blocked_events"
    echo "    Acessos temporários: $temp_grants"
    echo "    Usuários criados: $user_creates"
    echo ""
    
    if [[ "$format" == "json" ]]; then
        echo "  Eventos (JSON):"
        tail -50 "$AUDIT_LOG_FILE"
    else
        echo "  Últimos 20 eventos:"
        echo ""
        tail -20 "$AUDIT_LOG_FILE" | while IFS= read -r line; do
            local ts action user details
            ts=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
            action=$(echo "$line" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
            user=$(echo "$line" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)
            
            printf "    %-20s %-25s %s\n" "$ts" "$action" "$user"
        done
    fi
    echo ""
}

# Relatório de sessões
session_report() {
    local user="${1:-}"
    local days="${2:-7}"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              RELATÓRIO DE SESSÕES (últimos $days dias)           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ ! -d "$SESSION_LOG_DIR" ]]; then
        echo "  Nenhum registro de sessão encontrado"
        return 0
    fi
    
    local since
    since=$(date -d "-${days} days" '+%Y-%m-%d')
    
    if [[ -n "$user" ]]; then
        echo "  Usuário: $user"
        echo "  Período: $since até $(_date)"
        echo ""
        
        # Lista sessões do usuário
        for log_file in "$SESSION_LOG_DIR"/${user}_*.log; do
            [[ ! -f "$log_file" ]] && continue
            
            local log_date
            log_date=$(basename "$log_file" .log | cut -d'_' -f2)
            
            [[ "$log_date" < "$since" ]] && continue
            
            echo "  📅 $log_date:"
            head -20 "$log_file" | while IFS= read -r line; do
                echo "    $line"
            done
            echo ""
        done
    else
        echo "  Resumo por usuário:"
        echo ""
        
        # Conta comandos por usuário
        declare -A user_commands
        
        for log_file in "$SESSION_LOG_DIR"/*.log; do
            [[ ! -f "$log_file" ]] && continue
            
            local log_user
            log_user=$(basename "$log_file" .log | cut -d'_' -f1)
            local count
            count=$(wc -l < "$log_file")
            
            user_commands[$log_user]=$((${user_commands[$log_user]:-0} + count))
        done
        
        for u in "${!user_commands[@]}"; do
            printf "    %-20s %d comandos\n" "$u" "${user_commands[$u]}"
        done
    fi
    echo ""
}

# Health check
health_check() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                      HEALTH CHECK                                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    local errors=0
    local warnings=0
    
    # Verifica grupos
    echo "  [GRUPOS]"
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        if group_exists "$group"; then
            local members
            members=$(getent group "$group" | cut -d: -f4)
            local count=0
            [[ -n "$members" ]] && count=$(echo "$members" | tr ',' '\n' | wc -l)
            echo -e "    ${GREEN}✓${NC} $group ($count membros)"
        else
            echo -e "    ${RED}✗${NC} $group (NÃO EXISTE)"
            ((errors++))
        fi
    done
    echo ""
    
    # Verifica sudoers
    echo "  [SUDOERS]"
    if [[ -f "$SUDO_FILE" ]]; then
        if visudo -c -f "$SUDO_FILE" &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} $SUDO_FILE (válido)"
        else
            echo -e "    ${RED}✗${NC} $SUDO_FILE (INVÁLIDO)"
            ((errors++))
        fi
    else
        echo -e "    ${YELLOW}○${NC} $SUDO_FILE (não existe)"
        ((warnings++))
    fi
    echo ""
    
    # Verifica wrapper
    echo "  [DOCKER WRAPPER]"
    if [[ -f "$DOCKER_WRAPPER_PATH" ]]; then
        if [[ -x "$DOCKER_WRAPPER_PATH" ]]; then
            echo -e "    ${GREEN}✓${NC} $DOCKER_WRAPPER_PATH (executável)"
        else
            echo -e "    ${YELLOW}○${NC} $DOCKER_WRAPPER_PATH (não executável)"
            ((warnings++))
        fi
    else
        echo -e "    ${YELLOW}○${NC} $DOCKER_WRAPPER_PATH (não existe)"
        ((warnings++))
    fi
    echo ""
    
    # Verifica diretórios de log
    echo "  [DIRETÓRIOS DE LOG]"
    for dir in "${LOG_DIRS_ALLOWED[@]}"; do
        if [[ -d "$dir" ]]; then
            echo -e "    ${GREEN}✓${NC} $dir"
        else
            echo -e "    ${YELLOW}○${NC} $dir (não existe)"
        fi
    done
    echo ""
    
    # Verifica cron
    echo "  [CRON JOBS]"
    if [[ -f "$CRON_FILE" ]]; then
        echo -e "    ${GREEN}✓${NC} $CRON_FILE"
    else
        echo -e "    ${YELLOW}○${NC} $CRON_FILE (não configurado)"
        ((warnings++))
    fi
    echo ""
    
    # Verifica acessos temporários
    echo "  [ACESSOS TEMPORÁRIOS]"
    local temp_count=0
    local expired_count=0
    local now
    now=$(date +%s)
    
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
            [[ ! -f "$expiry_file" ]] && continue
            ((temp_count++))
            
            local expiry
            expiry=$(cat "$expiry_file")
            [[ $now -gt $expiry ]] && ((expired_count++))
        done
    fi
    
    echo "    Ativos: $((temp_count - expired_count))"
    echo "    Expirados: $expired_count"
    echo ""
    
    # Resumo
    echo "  ═══════════════════════════════════════════════════════════════"
    if [[ $errors -gt 0 ]]; then
        echo -e "    ${RED}RESULTADO: $errors erros, $warnings avisos${NC}"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        echo -e "    ${YELLOW}RESULTADO: OK com $warnings avisos${NC}"
        return 0
    else
        echo -e "    ${GREEN}RESULTADO: Tudo OK${NC}"
        return 0
    fi
}

# Envia relatório semanal
send_report() {
    log_info "Gerando relatório semanal..."
    
    local report=""
    
    # Cabeçalho
    report+="📊 *Relatório Semanal - DevOps Permissions Manager*\n"
    report+="Ambiente: $ENVIRONMENT\n"
    report+="Data: $(_date)\n\n"
    
    # Grupos
    report+="*Grupos:*\n"
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        if group_exists "$group"; then
            local members
            members=$(getent group "$group" | cut -d: -f4)
            local count=0
            [[ -n "$members" ]] && count=$(echo "$members" | tr ',' '\n' | wc -l)
            report+="• $group: $count membros\n"
        fi
    done
    report+="\n"
    
    # Acessos temporários
    local temp_count=0
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        temp_count=$(find "$TEMP_ACCESS_DIR" -name "*.expiry" 2>/dev/null | wc -l)
    fi
    report+="*Acessos Temporários Ativos:* $temp_count\n"
    
    # Solicitações pendentes
    local req_count=0
    if [[ -d "$REQUESTS_DIR" ]]; then
        req_count=$(find "$REQUESTS_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
    fi
    report+="*Solicitações Pendentes:* $req_count\n"
    
    send_webhook "📊 Relatório Semanal" "$report" "info"
    
    log_ok "Relatório enviado"
}

#===============================================================================
# STATUS E DASHBOARD
#===============================================================================

# Mostra status do sistema
show_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           DEVS PERMISSIONS MANAGER - STATUS                      ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    echo -e "${BOLD}[AMBIENTE]${NC}"
    echo "  Ambiente: $ENVIRONMENT"
    echo "  Versão: $SCRIPT_VERSION"
    echo "  Config: $CONFIG_FILE"
    echo ""
    
    echo -e "${BOLD}[GRUPOS]${NC}"
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        if group_exists "$group"; then
            local members
            members=$(getent group "$group" | cut -d: -f4)
            echo -e "  ${GREEN}✓${NC} $group: ${members:-nenhum}"
        else
            echo -e "  ${RED}✗${NC} $group: NÃO EXISTE"
        fi
    done
    echo ""
    
    echo -e "${BOLD}[CONFIGURAÇÕES]${NC}"
    echo "  Controle de horário: $ACCESS_HOURS_ENABLED"
    [[ "$ACCESS_HOURS_ENABLED" == true ]] && echo "    Horário: $ACCESS_HOURS_START - $ACCESS_HOURS_END"
    echo "  Auto-criar usuários: $AUTO_CREATE_USERS"
    echo "  Revogação por inatividade: $AUTO_REVOKE_INACTIVE (${INACTIVITY_DAYS} dias)"
    echo "  Restrição por time: $TEAM_RESTRICTION_ENABLED"
    echo "  Webhook: ${WEBHOOK_URL:-não configurado}"
    echo ""
    
    # Times
    if [[ "$TEAM_RESTRICTION_ENABLED" == true ]] && [[ ${#TEAMS[@]} -gt 0 ]]; then
        echo -e "${BOLD}[TIMES/PROJETOS]${NC}"
        for team in "${TEAMS[@]}"; do
            local users_var="TEAM_${team}_USERS"
            local containers_var="TEAM_${team}_CONTAINERS"
            
            if declare -p "$users_var" &>/dev/null; then
                local -a team_users team_containers
                eval "team_users=(\"\${${users_var}[@]}\")"
                eval "team_containers=(\"\${${containers_var}[@]}\")" 2>/dev/null || team_containers=()
                
                if [[ ${#team_users[@]} -gt 0 ]]; then
                    echo -e "  ${CYAN}▶${NC} $team"
                    echo "    Containers: ${team_containers[*]:-*}"
                    echo "    Usuários: ${team_users[*]}"
                fi
            fi
        done
        echo ""
    fi
    
    echo -e "${BOLD}[ACESSOS TEMPORÁRIOS]${NC}"
    local temp_count=0
    local now
    now=$(date +%s)
    
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
            [[ ! -f "$expiry_file" ]] && continue
            
            ((temp_count++))
            local user
            user=$(basename "$expiry_file" .expiry)
            local expiry
            expiry=$(cat "$expiry_file")
            local remaining=$(( (expiry - now) / 3600 ))
            
            if [[ $remaining -gt 0 ]]; then
                echo -e "  ${GREEN}●${NC} $user: ${remaining}h restantes"
            else
                echo -e "  ${RED}●${NC} $user: EXPIRADO"
            fi
        done
    fi
    
    [[ $temp_count -eq 0 ]] && echo "  Nenhum"
    echo ""
    
    echo -e "${BOLD}[AUDITORIA]${NC}"
    if [[ -f "$AUDIT_LOG_FILE" ]]; then
        local events
        events=$(wc -l < "$AUDIT_LOG_FILE")
        echo -e "  ${GREEN}✓${NC} Log: $events eventos"
    else
        echo -e "  ${YELLOW}○${NC} Log não existe"
    fi
    
    [[ -f "$DOCKER_WRAPPER_PATH" ]] && echo -e "  ${GREEN}✓${NC} Wrapper instalado" || echo -e "  ${YELLOW}○${NC} Wrapper não instalado"
    [[ -f "$CRON_FILE" ]] && echo -e "  ${GREEN}✓${NC} Cron jobs ativos" || echo -e "  ${YELLOW}○${NC} Cron não configurado"
    echo ""
}

# Dashboard compacto
show_dashboard() {
    clear
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║               🖥️  DEVS PERMISSIONS DASHBOARD - $ENVIRONMENT               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Linha 1: Grupos
    local dev_count=0 exec_count=0 webconf_count=0
    
    if group_exists "$GRUPO_DEV"; then
        local members
        members=$(getent group "$GRUPO_DEV" | cut -d: -f4)
        [[ -n "$members" ]] && dev_count=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    if group_exists "$GRUPO_DEV_EXEC"; then
        local members
        members=$(getent group "$GRUPO_DEV_EXEC" | cut -d: -f4)
        [[ -n "$members" ]] && exec_count=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    if group_exists "$GRUPO_DEV_WEBCONF"; then
        local members
        members=$(getent group "$GRUPO_DEV_WEBCONF" | cut -d: -f4)
        [[ -n "$members" ]] && webconf_count=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    echo -e "  ${BOLD}GRUPOS${NC}"
    echo -e "  ┌────────────────┬────────────────┬────────────────┐"
    printf "  │ %-14s │ %-14s │ %-14s │\n" "Básico" "Exec" "WebConf"
    printf "  │ %-14s │ %-14s │ %-14s │\n" "$dev_count usuários" "$exec_count usuários" "$webconf_count usuários"
    echo -e "  └────────────────┴────────────────┴────────────────┘"
    echo ""
    
    # Linha 2: Acessos temporários e solicitações
    local temp_count=0 req_count=0
    
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        temp_count=$(find "$TEMP_ACCESS_DIR" -name "*.expiry" 2>/dev/null | wc -l)
    fi
    
    if [[ -d "$REQUESTS_DIR" ]]; then
        req_count=$(find "$REQUESTS_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
    fi
    
    echo -e "  ${BOLD}ACESSOS${NC}"
    echo -e "  ┌────────────────────────────┬────────────────────────────┐"
    printf "  │ 🔓 Temporários: %-10s │ 📋 Pendentes: %-12s │\n" "$temp_count ativos" "$req_count"
    echo -e "  └────────────────────────────┴────────────────────────────┘"
    echo ""
    
    # Lista de acessos temporários
    if [[ $temp_count -gt 0 ]]; then
        echo -e "  ${BOLD}ACESSOS TEMPORÁRIOS ATIVOS${NC}"
        local now
        now=$(date +%s)
        
        for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
            [[ ! -f "$expiry_file" ]] && continue
            
            local user
            user=$(basename "$expiry_file" .expiry)
            local expiry
            expiry=$(cat "$expiry_file")
            local remaining=$(( (expiry - now) / 3600 ))
            
            if [[ $remaining -gt 0 ]]; then
                echo -e "    ${GREEN}●${NC} $user (${remaining}h)"
            else
                echo -e "    ${RED}●${NC} $user (expirado)"
            fi
        done
        echo ""
    fi
    
    # Solicitações pendentes
    if [[ $req_count -gt 0 ]]; then
        echo -e "  ${BOLD}SOLICITAÇÕES PENDENTES${NC}"
        
        for request_file in "$REQUESTS_DIR"/*.json; do
            [[ ! -f "$request_file" ]] && continue
            
            local id user hours
            id=$(grep -o '"id": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            user=$(grep -o '"user": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            hours=$(grep -o '"hours": *[0-9]*' "$request_file" | grep -o '[0-9]*')
            
            echo -e "    ${YELLOW}●${NC} $id - $user (${hours}h)"
        done
        echo ""
    fi
    
    # Footer
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}Atualizado: $(_ts) | v$SCRIPT_VERSION${NC}"
    echo ""
}

#===============================================================================
# SINCRONIZAÇÃO DE GRUPOS
#===============================================================================

# Verifica se usuário está em um array
user_in_array() {
    local user="$1"
    shift
    local array=("$@")
    
    for item in "${array[@]}"; do
        [[ "$item" == "$user" ]] && return 0
    done
    return 1
}

# Sincroniza membros dos grupos com a configuração
# Remove usuários que não estão mais nos arrays de configuração
sync_group_members() {
    log_info "Sincronizando grupos com configuração..."
    
    local removed_count=0
    
    # ══════════════════════════════════════════════════════════════════════════
    # SINCRONIZA GRUPO BÁSICO (devs)
    # ══════════════════════════════════════════════════════════════════════════
    if group_exists "$GRUPO_DEV"; then
        log_debug "Sincronizando $GRUPO_DEV..."
        
        local current_members
        current_members=$(getent group "$GRUPO_DEV" | cut -d: -f4)
        
        if [[ -n "$current_members" ]]; then
            IFS=',' read -ra members_array <<< "$current_members"
            
            for member in "${members_array[@]}"; do
                [[ -z "$member" ]] && continue
                
                # Verifica se está em USUARIOS, USUARIOS_EXEC ou USUARIOS_WEBCONF
                local should_be_in_group=false
                
                if user_in_array "$member" "${USUARIOS[@]}"; then
                    should_be_in_group=true
                elif user_in_array "$member" "${USUARIOS_EXEC[@]}"; then
                    should_be_in_group=true
                elif user_in_array "$member" "${USUARIOS_WEBCONF[@]}"; then
                    should_be_in_group=true
                fi
                
                if [[ "$should_be_in_group" == false ]]; then
                    log_warn "Removendo $member de $GRUPO_DEV (não está na configuração)"
                    
                    if [[ "$DRY_RUN" != true ]]; then
                        remove_user_from_group "$member" "$GRUPO_DEV"
                        audit_log "USER_SYNC_REMOVED" "root" "user=$member,group=$GRUPO_DEV,reason=not_in_config"
                    else
                        log_dry "Removeria $member de $GRUPO_DEV"
                    fi
                    
                    ((removed_count++))
                fi
            done
        fi
    fi
    
    # ══════════════════════════════════════════════════════════════════════════
    # SINCRONIZA GRUPO EXEC (devs_exec)
    # ══════════════════════════════════════════════════════════════════════════
    if group_exists "$GRUPO_DEV_EXEC"; then
        log_debug "Sincronizando $GRUPO_DEV_EXEC..."
        
        local current_members
        current_members=$(getent group "$GRUPO_DEV_EXEC" | cut -d: -f4)
        
        if [[ -n "$current_members" ]]; then
            IFS=',' read -ra members_array <<< "$current_members"
            
            for member in "${members_array[@]}"; do
                [[ -z "$member" ]] && continue
                
                # Verifica se está em USUARIOS_EXEC
                if ! user_in_array "$member" "${USUARIOS_EXEC[@]}"; then
                    # Verifica se tem acesso temporário ativo
                    local has_temp_access=false
                    if [[ -f "${TEMP_ACCESS_DIR}/${member}.expiry" ]]; then
                        local expiry now
                        expiry=$(cat "${TEMP_ACCESS_DIR}/${member}.expiry" 2>/dev/null || echo "0")
                        now=$(date +%s)
                        [[ $expiry -gt $now ]] && has_temp_access=true
                    fi
                    
                    if [[ "$has_temp_access" == false ]]; then
                        log_warn "Removendo $member de $GRUPO_DEV_EXEC (não está na configuração)"
                        
                        if [[ "$DRY_RUN" != true ]]; then
                            remove_user_from_group "$member" "$GRUPO_DEV_EXEC"
                            audit_log "USER_SYNC_REMOVED" "root" "user=$member,group=$GRUPO_DEV_EXEC,reason=not_in_config"
                        else
                            log_dry "Removeria $member de $GRUPO_DEV_EXEC"
                        fi
                        
                        ((removed_count++))
                    else
                        log_debug "$member tem acesso temporário ativo, mantendo em $GRUPO_DEV_EXEC"
                    fi
                fi
            done
        fi
    fi
    
    # ══════════════════════════════════════════════════════════════════════════
    # SINCRONIZA GRUPO WEBCONF (devs_webconf)
    # ══════════════════════════════════════════════════════════════════════════
    if group_exists "$GRUPO_DEV_WEBCONF"; then
        log_debug "Sincronizando $GRUPO_DEV_WEBCONF..."
        
        local current_members
        current_members=$(getent group "$GRUPO_DEV_WEBCONF" | cut -d: -f4)
        
        if [[ -n "$current_members" ]]; then
            IFS=',' read -ra members_array <<< "$current_members"
            
            for member in "${members_array[@]}"; do
                [[ -z "$member" ]] && continue
                
                # Verifica se está em USUARIOS_WEBCONF
                if ! user_in_array "$member" "${USUARIOS_WEBCONF[@]}"; then
                    log_warn "Removendo $member de $GRUPO_DEV_WEBCONF (não está na configuração)"
                    
                    if [[ "$DRY_RUN" != true ]]; then
                        remove_user_from_group "$member" "$GRUPO_DEV_WEBCONF"
                        audit_log "USER_SYNC_REMOVED" "root" "user=$member,group=$GRUPO_DEV_WEBCONF,reason=not_in_config"
                    else
                        log_dry "Removeria $member de $GRUPO_DEV_WEBCONF"
                    fi
                    
                    ((removed_count++))
                fi
            done
        fi
    fi
    
    if [[ $removed_count -gt 0 ]]; then
        log_ok "Sincronização: $removed_count usuários removidos de grupos"
    else
        log_ok "Sincronização: grupos já estão sincronizados"
    fi
}

#===============================================================================
# COMANDOS PRINCIPAIS
#===============================================================================

# Comando: apply
cmd_apply() {
    log_info "═══════════════════════════════════════════════════════"
    log_info " APLICANDO CONFIGURAÇÕES | Ambiente: $ENVIRONMENT"
    log_info "═══════════════════════════════════════════════════════"
    
    # Mostra resumo
    echo ""
    echo -e "${BOLD}📋 RESUMO DAS ALTERAÇÕES:${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    
    # Grupos
    echo -e "${BOLD}Grupos:${NC}"
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        if group_exists "$group"; then
            echo -e "  ${GREEN}✓${NC} $group (já existe)"
        else
            echo -e "  ${YELLOW}+${NC} $group (será criado)"
        fi
    done
    echo ""
    
    # Usuários básicos
    echo -e "${BOLD}Usuários - Nível Básico (${#USUARIOS[@]} configurados):${NC}"
    local new_users=0 existing_users=0
    for user in "${USUARIOS[@]}"; do
        [[ -z "$user" ]] && continue
        
        if user_exists "$user"; then
            if user_in_group "$user" "$GRUPO_DEV"; then
                echo -e "  ${GREEN}✓${NC} $user (já configurado)"
            else
                echo -e "  ${CYAN}~${NC} $user (será adicionado ao grupo)"
            fi
            ((existing_users++)) || true
        else
            echo -e "  ${YELLOW}+${NC} $user (será criado)"
            ((new_users++)) || true
        fi
    done
    echo ""
    
    # Usuários exec
    echo -e "${BOLD}Usuários - Nível Exec (${#USUARIOS_EXEC[@]} configurados):${NC}"
    if [[ ${#USUARIOS_EXEC[@]} -eq 0 ]]; then
        echo "  (nenhum configurado)"
    else
        for user in "${USUARIOS_EXEC[@]}"; do
            [[ -z "$user" ]] && continue
            
            if user_exists "$user"; then
                if user_in_group "$user" "$GRUPO_DEV_EXEC"; then
                    echo -e "  ${GREEN}✓${NC} $user (já configurado)"
                else
                    echo -e "  ${CYAN}~${NC} $user (será adicionado ao grupo)"
                fi
            else
                echo -e "  ${YELLOW}+${NC} $user (será criado)"
            fi
        done
    fi
    echo ""
    
    # Usuários webconf
    echo -e "${BOLD}Usuários - Nível WebConf (${#USUARIOS_WEBCONF[@]} configurados):${NC}"
    if [[ ${#USUARIOS_WEBCONF[@]} -eq 0 ]]; then
        echo "  (nenhum configurado)"
    else
        for user in "${USUARIOS_WEBCONF[@]}"; do
            [[ -z "$user" ]] && continue
            
            if user_exists "$user"; then
                if user_in_group "$user" "$GRUPO_DEV_WEBCONF"; then
                    echo -e "  ${GREEN}✓${NC} $user (já configurado)"
                else
                    echo -e "  ${CYAN}~${NC} $user (será adicionado ao grupo)"
                fi
            else
                echo -e "  ${YELLOW}+${NC} $user (será criado)"
            fi
        done
    fi
    echo ""
    
    # Times
    if [[ "$TEAM_RESTRICTION_ENABLED" == true ]] && [[ ${#TEAMS[@]} -gt 0 ]]; then
        echo -e "${BOLD}Times/Projetos:${NC}"
        for team in "${TEAMS[@]}"; do
            local users_var="TEAM_${team}_USERS"
            local containers_var="TEAM_${team}_CONTAINERS"
            
            if declare -p "$users_var" &>/dev/null; then
                local -a team_users team_containers
                eval "team_users=(\"\${${users_var}[@]}\")"
                eval "team_containers=(\"\${${containers_var}[@]}\")" 2>/dev/null || team_containers=("*")
                
                local user_count=${#team_users[@]}
                [[ $user_count -gt 0 ]] && echo -e "  ${CYAN}▶${NC} $team: $user_count usuários → ${team_containers[*]}"
            fi
        done
        echo ""
    fi
    
    echo "─────────────────────────────────────────────────────────────"
    echo -e "  Usuários novos a criar: ${YELLOW}$new_users${NC}"
    echo -e "  Usuários existentes: ${GREEN}$existing_users${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    
    # Confirmação
    if ! confirm_action "Aplicar configurações?"; then
        log_info "Operação cancelada"
        return 0
    fi
    
    # Adquire lock para evitar execução concorrente
    if ! acquire_lock; then
        log_error "Não foi possível adquirir lock. Outro processo em execução?"
        return 1
    fi

    # Executa
    init_directories
    create_backup

    # Cria grupos
    ensure_group_exists "$GRUPO_DEV"
    ensure_group_exists "$GRUPO_DEV_EXEC"
    ensure_group_exists "$GRUPO_DEV_WEBCONF"
    
    # Processa usuários básicos
    log_info "Processando usuários básicos..."
    for user in "${USUARIOS[@]}"; do
        [[ -z "$user" ]] && continue
        create_user "$user" "$GRUPO_DEV"
        add_user_to_group "$user" "$GRUPO_DEV"
        configure_user_bashrc "$user"
    done
    
    # Processa usuários exec
    log_info "Processando usuários exec..."
    for user in "${USUARIOS_EXEC[@]}"; do
        [[ -z "$user" ]] && continue
        create_user "$user" "$GRUPO_DEV,$GRUPO_DEV_EXEC"
        add_user_to_group "$user" "$GRUPO_DEV"
        add_user_to_group "$user" "$GRUPO_DEV_EXEC"
        configure_user_bashrc "$user"
    done
    
    # Processa usuários webconf
    log_info "Processando usuários webconf..."
    for user in "${USUARIOS_WEBCONF[@]}"; do
        [[ -z "$user" ]] && continue
        create_user "$user" "$GRUPO_DEV,$GRUPO_DEV_WEBCONF"
        add_user_to_group "$user" "$GRUPO_DEV"
        add_user_to_group "$user" "$GRUPO_DEV_WEBCONF"
        configure_user_bashrc "$user"
    done
    
    # SINCRONIZA GRUPOS - Remove usuários que não estão mais na configuração
    sync_group_members
    
    # Configura sistema
    cleanup_old_sudoers
    configure_sudoers
    configure_acls
    create_docker_wrapper
    setup_logrotate
    setup_cron_jobs
    
    audit_log "SYSTEM_CONFIGURED" "root" "version=$SCRIPT_VERSION,environment=$ENVIRONMENT"
    
    echo ""
    log_ok "═══════════════════════════════════════════════════════"
    log_ok " CONFIGURAÇÃO CONCLUÍDA"
    log_ok "═══════════════════════════════════════════════════════"
    echo ""
    echo "RESUMO:"
    echo "  • Ambiente: $ENVIRONMENT"
    echo "  • Grupos: $GRUPO_DEV, $GRUPO_DEV_EXEC, $GRUPO_DEV_WEBCONF"
    echo "  • Usuários básicos: ${#USUARIOS[@]}"
    echo "  • Usuários exec: ${#USUARIOS_EXEC[@]}"
    echo "  • Usuários webconf: ${#USUARIOS_WEBCONF[@]}"
    echo ""
    echo "PRÓXIMOS PASSOS:"
    echo "  1. Usuários novos devem fazer login e trocar a senha"
    echo "  2. Usuários existentes devem fazer logout/login"
    echo "  3. Verifique: $SCRIPT_NAME status"
    echo "  4. Dashboard: $SCRIPT_NAME dashboard"
    echo ""

    release_lock
}

#===============================================================================
# LIMPEZA DE USUÁRIOS ÓRFÃOS
#===============================================================================

# Lista usuários que foram criados pelo script mas não estão mais na configuração
list_orphan_users() {
    log_info "Buscando usuários órfãos..."
    
    local -a orphan_users=()
    local -a config_users=()
    
    # Coleta todos os usuários da configuração
    for user in "${USUARIOS[@]}" "${USUARIOS_EXEC[@]}" "${USUARIOS_WEBCONF[@]}"; do
        [[ -z "$user" ]] && continue
        # Evita duplicatas
        local already=false
        for u in "${config_users[@]}"; do
            [[ "$u" == "$user" ]] && already=true && break
        done
        [[ "$already" == false ]] && config_users+=("$user")
    done
    
    # Verifica membros atuais dos grupos gerenciados
    local all_managed_users=""
    
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        if group_exists "$group"; then
            local members
            members=$(getent group "$group" | cut -d: -f4)
            [[ -n "$members" ]] && all_managed_users+=",$members"
        fi
    done
    
    # Também verifica arquivos de credenciais para encontrar usuários criados
    if [[ -d "$BACKUP_DIR/credentials" ]]; then
        for cred_file in "$BACKUP_DIR/credentials"/*.cred; do
            [[ ! -f "$cred_file" ]] && continue
            local cred_user
            cred_user=$(grep "Usuário:" "$cred_file" | awk '{print $2}')
            [[ -n "$cred_user" ]] && all_managed_users+=",$cred_user"
        done
    fi
    
    # Remove duplicatas e processa
    all_managed_users=$(echo "$all_managed_users" | tr ',' '\n' | sort -u | grep -v '^$')
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo " ANÁLISE DE USUÁRIOS ÓRFÃOS"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    local found_orphans=false
    
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        
        # Verifica se está na configuração
        local in_config=false
        for cfg_user in "${config_users[@]}"; do
            if [[ "$cfg_user" == "$user" ]]; then
                in_config=true
                break
            fi
        done
        
        if [[ "$in_config" == false ]]; then
            # Verifica se o usuário existe no sistema
            if user_exists "$user"; then
                found_orphans=true
                orphan_users+=("$user")
                
                local uid groups last_login
                uid=$(id -u "$user" 2>/dev/null || echo "?")
                groups=$(id -Gn "$user" 2>/dev/null | tr ' ' ',')
                last_login=$(lastlog -u "$user" 2>/dev/null | tail -1 | awk '{print $4, $5, $6, $7}' || echo "nunca")
                
                echo -e "  ${YELLOW}⚠${NC}  $user"
                echo "      UID: $uid | Grupos: $groups"
                echo "      Último login: $last_login"
                echo ""
            fi
        fi
    done <<< "$all_managed_users"
    
    if [[ "$found_orphans" == false ]]; then
        echo -e "  ${GREEN}✓${NC} Nenhum usuário órfão encontrado"
        echo ""
        return 0
    fi
    
    echo "───────────────────────────────────────────────────────────────────"
    echo -e "  Total de órfãos: ${YELLOW}${#orphan_users[@]}${NC}"
    echo ""
    echo "  Estes usuários existem no sistema mas NÃO estão na configuração."
    echo "  Podem ter sido criados em testes ou removidos da config."
    echo ""
    echo "  Para remover, execute:"
    echo -e "    ${CYAN}$SCRIPT_NAME cleanup-users${NC}"
    echo ""
    
    # Salva lista para uso pelo cleanup
    printf '%s\n' "${orphan_users[@]}" > ${BACKUP_DIR}/orphan_users.list
    
    return 0
}

# Remove usuários órfãos do sistema
cleanup_orphan_users() {
    log_info "═══════════════════════════════════════════════════════"
    log_info " LIMPEZA DE USUÁRIOS ÓRFÃOS"
    log_info "═══════════════════════════════════════════════════════"
    echo ""
    
    # Primeiro lista para mostrar o que será removido
    list_orphan_users
    
    # Verifica se há órfãos
    if [[ ! -f ${BACKUP_DIR}/orphan_users.list ]]; then
        log_info "Nenhum usuário órfão para limpar"
        return 0
    fi
    
    local -a orphan_users=()
    while IFS= read -r user; do
        [[ -n "$user" ]] && orphan_users+=("$user")
    done < ${BACKUP_DIR}/orphan_users.list
    
    if [[ ${#orphan_users[@]} -eq 0 ]]; then
        log_info "Nenhum usuário órfão para limpar"
        rm -f ${BACKUP_DIR}/orphan_users.list
        return 0
    fi
    
    echo ""
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED} ⚠  ATENÇÃO: Esta operação irá DELETAR os usuários acima!${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Usuários a serem deletados: ${orphan_users[*]}"
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Usuários que seriam deletados: ${orphan_users[*]}"
        rm -f ${BACKUP_DIR}/orphan_users.list
        return 0
    fi
    
    # Confirmação com palavra-chave (pulada em modo --force, ex: via Cockpit)
    if [[ "$FORCE" == true ]]; then
        log_info "Modo --force ativo, pulando confirmação interativa"
    else
        echo -e "  Digite ${YELLOW}DELETAR${NC} para confirmar a remoção:"
        read -r -p "  > " confirm

        if [[ "$confirm" != "DELETAR" ]]; then
            log_info "Operação cancelada"
            rm -f ${BACKUP_DIR}/orphan_users.list
            return 0
        fi
    fi
    
    echo ""
    create_backup
    
    local deleted=0
    local homes_removed=0
    
    for user in "${orphan_users[@]}"; do
        [[ -z "$user" ]] && continue
        
        # Proteções
        local uid
        uid=$(id -u "$user" 2>/dev/null || echo "0")
        
        if [[ $uid -lt 1000 ]]; then
            log_warn "Pulando usuário de sistema: $user (UID $uid)"
            continue
        fi
        
        # Lista de usuários protegidos (configurável via PROTECTED_USERS no config)
        local is_protected=false
        for pu in "${PROTECTED_USERS[@]}"; do
            [[ "$user" == "$pu" ]] && is_protected=true && break
        done
        
        if [[ "$is_protected" == true ]]; then
            log_warn "Pulando usuário protegido: $user"
            continue
        fi
        
        local user_home
        user_home=$(getent passwd "$user" | cut -d: -f6)
        
        log_info "Deletando usuário: $user"
        
        # Backup do home antes de qualquer coisa
        if [[ "$CMD_REMOVE_HOME" == true ]] && [[ -n "$user_home" ]] && [[ -d "$user_home" ]]; then
            local backup_dir="${BACKUP_DIR}/deleted_users/${user}_$(date +%Y%m%d%H%M%S)"
            mkdir -p "$backup_dir"
            tar -czf "${backup_dir}/home.tar.gz" -C "$(dirname "$user_home")" "$(basename "$user_home")" 2>/dev/null || true
            log_debug "Backup criado: $backup_dir"
        fi
        
        # Remove de todos os grupos primeiro
        for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
            gpasswd -d "$user" "$group" 2>/dev/null || true
        done
        
        # Encerra processos do usuário
        pkill -u "$user" 2>/dev/null || true
        sleep 1
        
        # Deleta o usuário
        local delete_ok=false
        
        if [[ "$CMD_REMOVE_HOME" == true ]]; then
            # Remove usuário E home
            if userdel -r "$user" 2>/dev/null; then
                delete_ok=true
            else
                # Fallback
                userdel "$user" 2>/dev/null && delete_ok=true
                [[ -n "$user_home" ]] && [[ -d "$user_home" ]] && rm -rf "$user_home"
            fi
            [[ "$delete_ok" == true ]] && ((homes_removed++))
        else
            # Remove APENAS usuário
            userdel "$user" 2>/dev/null && delete_ok=true
        fi
        
        if ! user_exists "$user"; then
            log_ok "Usuário deletado: $user"
            audit_log "USER_ORPHAN_DELETED" "root" "user=$user,home_removed=$CMD_REMOVE_HOME"
            ((deleted++))
        else
            log_error "Falha ao deletar: $user"
        fi
    done
    
    rm -f ${BACKUP_DIR}/orphan_users.list
    
    echo ""
    log_ok "Limpeza concluída: $deleted usuários removidos"
    
    if [[ "$CMD_REMOVE_HOME" == true ]]; then
        echo "  • Diretórios home removidos: $homes_removed"
        echo "  • Backups em: $BACKUP_DIR/deleted_users/"
    else
        echo ""
        echo "  NOTA: Os diretórios home foram mantidos em /home/"
        echo "  Para remover também os homes, use:"
        echo -e "    ${CYAN}$SCRIPT_NAME cleanup-users --remove-home${NC}"
    fi
    echo ""
}

# Comando: remove
cmd_remove() {
    log_info "═══════════════════════════════════════════════════════"
    log_info " REMOVENDO CONFIGURAÇÕES"
    log_info "═══════════════════════════════════════════════════════"
    
    if ! confirm_destructive "Remover TODAS as configurações do sistema?" "REMOVER"; then
        return 0
    fi
    
    create_backup
    
    # Remove sudoers
    if [[ -f "$SUDO_FILE" ]]; then
        log_info "Removendo sudoers..."
        rm -f "$SUDO_FILE"
    fi
    
    # Remove wrapper
    if [[ -f "$DOCKER_WRAPPER_PATH" ]]; then
        log_info "Removendo wrapper..."
        rm -f "$DOCKER_WRAPPER_PATH"
    fi
    
    # Remove cron
    if [[ -f "$CRON_FILE" ]]; then
        log_info "Removendo cron jobs..."
        rm -f "$CRON_FILE"
    fi
    
    audit_log "SYSTEM_REMOVED" "root" "version=$SCRIPT_VERSION"
    
    log_ok "Configurações removidas"
    log_info "Nota: Grupos e usuários NÃO foram removidos"
}

# Comando: add-user
cmd_add_user() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    log_info "Adicionando usuário: $CMD_USER"
    
    # Garante grupos
    ensure_group_exists "$GRUPO_DEV"
    [[ "$CMD_EXEC" == true ]] && ensure_group_exists "$GRUPO_DEV_EXEC"
    [[ "$CMD_WEBCONF" == true ]] && ensure_group_exists "$GRUPO_DEV_WEBCONF"
    
    # Cria usuário
    create_user "$CMD_USER" "$GRUPO_DEV"
    add_user_to_group "$CMD_USER" "$GRUPO_DEV"
    
    [[ "$CMD_EXEC" == true ]] && add_user_to_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    [[ "$CMD_WEBCONF" == true ]] && add_user_to_group "$CMD_USER" "$GRUPO_DEV_WEBCONF"
    
    configure_user_bashrc "$CMD_USER"
    
    audit_log "USER_ADDED" "root" "user=$CMD_USER,exec=$CMD_EXEC,webconf=$CMD_WEBCONF"
    log_ok "Usuário adicionado: $CMD_USER"
}

# Comando: remove-user
cmd_remove_user() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    log_info "Removendo permissões: $CMD_USER"
    
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_WEBCONF"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV"
    
    # Remove acesso temporário se houver
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.expiry" 2>/dev/null
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.reason" 2>/dev/null
    
    audit_log "USER_REMOVED" "root" "user=$CMD_USER"
    log_ok "Permissões removidas: $CMD_USER"
}

# Comando: reset-user
cmd_reset_user() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    if ! user_exists "$CMD_USER"; then
        log_error "Usuário não existe: $CMD_USER"
        return 1
    fi
    
    log_info "Resetando: $CMD_USER"
    
    if ! confirm_action "Remover TODAS as permissões de $CMD_USER?"; then
        log_info "Operação cancelada"
        return 0
    fi
    
    # Remove dos grupos
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_WEBCONF"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV"
    
    # Remove acesso temporário
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.expiry" 2>/dev/null
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.reason" 2>/dev/null
    
    # Limpa .bashrc
    local user_home
    user_home=$(getent passwd "$CMD_USER" | cut -d: -f6)
    if [[ -n "$user_home" ]] && [[ -f "${user_home}/.bashrc" ]]; then
        sed -i '/^# === DEVS PERMISSIONS ===/,/^# === END DEVS ===/d' "${user_home}/.bashrc" 2>/dev/null || true
    fi
    
    audit_log "USER_RESET" "root" "user=$CMD_USER"
    log_ok "Usuário resetado: $CMD_USER (mantido no sistema)"
}

# Comando: delete-user
cmd_delete_user() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    if ! user_exists "$CMD_USER"; then
        log_error "Usuário não existe: $CMD_USER"
        return 1
    fi
    
    local uid
    uid=$(id -u "$CMD_USER" 2>/dev/null)
    
    # Proteções
    if [[ $uid -lt 1000 ]]; then
        log_error "BLOQUEADO: Usuário do sistema (UID < 1000)"
        return 1
    fi
    
    if [[ "$CMD_USER" == "root" ]]; then
        log_error "BLOQUEADO: root"
        return 1
    fi
    
    if [[ "$CMD_USER" == "${SUDO_USER:-}" ]]; then
        log_error "BLOQUEADO: Não pode deletar a si mesmo"
        return 1
    fi
    
    local user_home
    user_home=$(getent passwd "$CMD_USER" | cut -d: -f6)
    
    local delete_home_msg=""
    if [[ "$CMD_REMOVE_HOME" == true ]]; then
        delete_home_msg="\n${RED}⚠ HOME SERÁ REMOVIDO: ${user_home}${NC}"
    else
        delete_home_msg="\n(Use --remove-home para deletar o diretório home)"
    fi
    
    if ! confirm_destructive "Usuário: $CMD_USER (UID: $uid)\nHome: ${user_home:-N/A}${delete_home_msg}" "$CMD_USER"; then
        return 0
    fi
    
    log_info "Deletando usuário: $CMD_USER"
    
    # Backup do home (sempre faz backup antes de qualquer operação)
    if [[ -n "$user_home" ]] && [[ -d "$user_home" ]]; then
        local backup_dir="${BACKUP_DIR}/deleted_users/${CMD_USER}_$(date +%Y%m%d%H%M%S)"
        mkdir -p "$backup_dir"
        log_info "Criando backup: $backup_dir"
        tar -czf "${backup_dir}/home.tar.gz" -C "$(dirname "$user_home")" "$(basename "$user_home")" 2>/dev/null || true
    fi
    
    # Remove dos grupos
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_WEBCONF"
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV"
    
    # Remove arquivos de acesso temporário
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.expiry" 2>/dev/null
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.reason" 2>/dev/null
    rm -f "${TEMP_ACCESS_DIR}/${CMD_USER}.lastactivity" 2>/dev/null
    
    # Encerra processos
    pkill -u "$CMD_USER" 2>/dev/null || true
    sleep 1
    
    # Deleta usuário
    local delete_success=false
    
    if [[ "$CMD_REMOVE_HOME" == true ]]; then
        # Remove usuário E home
        if userdel -r "$CMD_USER" 2>/dev/null; then
            delete_success=true
            log_debug "userdel -r executado com sucesso"
        else
            # Fallback: remove usuário e depois o home manualmente
            if userdel "$CMD_USER" 2>/dev/null; then
                delete_success=true
                log_debug "userdel executado, removendo home manualmente"
                if [[ -n "$user_home" ]] && [[ -d "$user_home" ]]; then
                    rm -rf "$user_home"
                    log_info "Home removido: $user_home"
                fi
            fi
        fi
    else
        # Remove APENAS o usuário, mantém home
        if userdel "$CMD_USER" 2>/dev/null; then
            delete_success=true
            log_debug "userdel executado (home mantido)"
        fi
    fi
    
    if [[ "$delete_success" == true ]]; then
        audit_log "USER_DELETED" "root" "user=$CMD_USER,uid=$uid,home_removed=$CMD_REMOVE_HOME"
        log_ok "Usuário deletado: $CMD_USER"
        
        if [[ "$CMD_REMOVE_HOME" != true ]] && [[ -d "$user_home" ]]; then
            echo ""
            log_warn "Home mantido em: $user_home"
            echo "  Para remover: rm -rf $user_home"
        fi
    else
        log_error "Não foi possível remover usuário: $CMD_USER"
        return 1
    fi
}

# Comando: promote
cmd_promote() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    if ! user_exists "$CMD_USER"; then
        log_error "Usuário não existe: $CMD_USER"
        return 1
    fi
    
    ensure_group_exists "$GRUPO_DEV_EXEC"
    add_user_to_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    
    audit_log "USER_PROMOTED" "root" "user=$CMD_USER"
    log_ok "Usuário promovido para exec: $CMD_USER"
}

# Comando: demote
cmd_demote() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    remove_user_from_group "$CMD_USER" "$GRUPO_DEV_EXEC"
    
    audit_log "USER_DEMOTED" "root" "user=$CMD_USER"
    log_ok "Usuário removido do exec: $CMD_USER"
}

# Comando: grant-temp
cmd_grant_temp() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME --hours N"
        return 1
    fi
    
    grant_temp_access "$CMD_USER" "$CMD_HOURS" "$CMD_REASON"
}

# Comando: revoke-temp
cmd_revoke_temp() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME"
        return 1
    fi
    
    revoke_temp_access "$CMD_USER" "manual"
}

# Comando: list-users
cmd_list_users() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                        LISTA DE USUÁRIOS                                             ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Cabeçalho com larguras fixas
    printf "%-20s %-5s %-5s %-5s %-6s %-22s %-30s\n" "USUÁRIO" "DEV" "EXEC" "WEB" "TEMP" "TIME(S)" "CONTAINERS"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    local -A seen
    local now
    now=$(date +%s)
    
    for group in "$GRUPO_DEV" "$GRUPO_DEV_EXEC" "$GRUPO_DEV_WEBCONF"; do
        group_exists "$group" || continue
        
        local members
        members=$(getent group "$group" | cut -d: -f4)
        
        IFS=',' read -ra users <<< "$members"
        for user in "${users[@]}"; do
            [[ -z "$user" ]] && continue
            [[ -n "${seen[$user]:-}" ]] && continue
            seen[$user]=1
            
            local dev_sym="" exec_sym="" web_sym="" temp_str="" teams_str="" containers_str=""
            
            # Verifica grupos
            if user_in_group "$user" "$GRUPO_DEV"; then
                dev_sym="✓"
            else
                dev_sym="✗"
            fi
            
            if user_in_group "$user" "$GRUPO_DEV_EXEC"; then
                exec_sym="✓"
            else
                exec_sym="✗"
            fi
            
            if user_in_group "$user" "$GRUPO_DEV_WEBCONF"; then
                web_sym="✓"
            else
                web_sym="✗"
            fi
            
            # Acesso temporário
            if [[ -f "${TEMP_ACCESS_DIR}/${user}.expiry" ]]; then
                local expiry
                expiry=$(cat "${TEMP_ACCESS_DIR}/${user}.expiry")
                local remaining=$(( (expiry - now) / 3600 ))
                
                if [[ $remaining -gt 0 ]]; then
                    temp_str="${remaining}h"
                else
                    temp_str="exp"
                fi
            else
                temp_str="-"
            fi
            
            # Times (suporta múltiplos)
            local user_teams_list
            if user_teams_list=$(get_user_teams "$user" 2>/dev/null); then
                # Formata lista de times (máx 20 chars)
                if [[ ${#user_teams_list} -gt 20 ]]; then
                    teams_str="${user_teams_list:0:17}..."
                else
                    teams_str="$user_teams_list"
                fi
                
                # Containers de todos os times
                containers_str=$(get_user_all_containers "$user")
                # Trunca se muito longo (máx 28 chars)
                if [[ ${#containers_str} -gt 28 ]]; then
                    containers_str="${containers_str:0:25}..."
                fi
            else
                teams_str="-"
                containers_str="* (todos)"
            fi
            
            # Imprime linha com cores
            printf "%-20s " "$user"
            [[ "$dev_sym" == "✓" ]] && printf "${GREEN}%-5s${NC}" "$dev_sym" || printf "${RED}%-5s${NC}" "$dev_sym"
            [[ "$exec_sym" == "✓" ]] && printf "${GREEN}%-5s${NC}" "$exec_sym" || printf "${RED}%-5s${NC}" "$exec_sym"
            [[ "$web_sym" == "✓" ]] && printf "${GREEN}%-5s${NC}" "$web_sym" || printf "${RED}%-5s${NC}" "$web_sym"
            [[ "$temp_str" != "-" && "$temp_str" != "exp" ]] && printf "${YELLOW}%-6s${NC}" "$temp_str" || printf "%-6s" "$temp_str"
            printf "%-22s %-30s\n" "$teams_str" "$containers_str"
        done
    done
    
    echo ""
    if [[ "$TEAM_RESTRICTION_ENABLED" == true ]]; then
        echo -e "${DIM}Legenda: TIME='-' significa acesso a TODOS os containers${NC}"
        echo -e "${DIM}         Usuário pode pertencer a múltiplos times${NC}"
    fi
    echo ""
}

# Comando: request
cmd_request() {
    if [[ -z "$CMD_USER" ]]; then
        log_error "Use --user NOME --hours N --reason \"motivo\""
        return 1
    fi
    
    if [[ -z "$CMD_REASON" ]]; then
        log_error "Motivo é obrigatório: --reason \"motivo\""
        return 1
    fi
    
    create_request "$CMD_USER" "$CMD_HOURS" "$CMD_REASON"
}

# Comando: approve
cmd_approve() {
    if [[ -z "$CMD_REQUEST_ID" ]]; then
        log_error "Use --request-id ID"
        return 1
    fi
    
    approve_request "$CMD_REQUEST_ID" "$CMD_APPROVER"
}

# Comando: deny
cmd_deny() {
    if [[ -z "$CMD_REQUEST_ID" ]]; then
        log_error "Use --request-id ID"
        return 1
    fi
    
    deny_request "$CMD_REQUEST_ID" "$CMD_REASON"
}

#===============================================================================
# HELP E VERSÃO
#===============================================================================

show_help() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║        DEVS PERMISSIONS MANAGER v5.0.0 - Production Ready Edition            ║
║                        Equipe DevOps - DETRAN-CE                             ║
╚══════════════════════════════════════════════════════════════════════════════╝

USO: devs_permissions_manager.sh [OPÇÕES] [COMANDO]

COMANDOS PRINCIPAIS:
    apply              Aplica todas as configurações
    remove             Remove todas as configurações
    status             Mostra status detalhado
    dashboard          Dashboard visual compacto
    validate           Valida configurações

GESTÃO DE USUÁRIOS:
    add-user           Adiciona usuário (--user NOME [--exec] [--webconf])
    remove-user        Remove do grupo de permissões (--user NOME)
    reset-user         Remove permissões e limpa .bashrc (--user NOME)
    delete-user        ⚠️  DELETA completamente do sistema (--user NOME [--remove-home])
    promote            Promove para exec (--user NOME)
    demote             Remove exec (--user NOME)
    list-users         Lista todos os usuários

ACESSO TEMPORÁRIO:
    grant-temp         Concede acesso temporário
                       --user NOME --hours N [--reason "motivo"]
    revoke-temp        Revoga acesso temporário (--user NOME)

SELF-SERVICE (Solicitações):
    request            Solicita acesso (--user NOME --hours N --reason "motivo")
    approve            Aprova solicitação (--request-id ID [--approver NOME])
    deny               Nega solicitação (--request-id ID [--reason "motivo"])
    list-requests      Lista solicitações pendentes

AUDITORIA:
    audit-report       Relatório (--days N [--user NOME] [--format json|text])
    audit-tail         Monitor em tempo real
    session-report     Relatório de sessões (--user NOME --days N)
    health-check       Verifica saúde do sistema
    inactive-users     Lista usuários inativos (--days N)

MANUTENÇÃO:
    cleanup            Remove acessos expirados e usuários inativos
    sync               Sincroniza grupos com config (remove usuários não listados)
    list-orphans       Lista usuários criados mas não mais na config
    cleanup-users      Remove usuários órfãos do sistema ([--remove-home])
    backup             Cria backup
    list-backups       Lista backups
    send-report        Envia relatório semanal

OPÇÕES:
    -c, --config FILE     Arquivo de configuração
    -d, --dry-run         Simula sem alterar
    -f, --force           Sem confirmações
    -v, --verbose         Modo verboso
    -e, --env ENV         Sobrescreve ambiente (development/staging/production)
    -s, --skip-backup     Pula criação de backup
    -h, --help            Esta ajuda
    -V, --version         Mostra versão

EXEMPLOS:
    # Setup inicial
    sudo devs_permissions_manager.sh apply

    # Adicionar desenvolvedor
    sudo devs_permissions_manager.sh add-user --user joao.silva
    sudo devs_permissions_manager.sh add-user --user maria.santos --exec
    sudo devs_permissions_manager.sh add-user --user pedro.costa --webconf
    sudo devs_permissions_manager.sh add-user --user ana.lima --exec --webconf

    # Acesso temporário (com motivo para auditoria)
    sudo devs_permissions_manager.sh grant-temp --user joao --hours 4 --reason "debug #123"

    # Self-service: dev solicita acesso
    sudo devs_permissions_manager.sh request --user joao --hours 2 --reason "deploy hotfix"
    
    # Aprovador aprova
    sudo devs_permissions_manager.sh approve --request-id REQ-20250123-001

    # Dashboard rápido
    sudo devs_permissions_manager.sh dashboard

    # Usuários inativos há mais de 30 dias
    sudo devs_permissions_manager.sh inactive-users --days 30

NÍVEIS DE ACESSO:
    BÁSICO (devs):          docker ps/logs/inspect, leitura de logs
    EXEC (devs_exec):       básico + docker exec (entrar no container)
    WEBCONF (devs_webconf): básico + editar nginx/httpd configs + reload

AMBIENTES:
    development   - Menos restrições, acesso mais livre (max 48h temp)
    staging       - Restrições moderadas (max 12h temp)
    production    - Máxima restrição, exec pode requerer aprovação (max 4h temp)

RESTRIÇÃO POR TIME:
    Quando TEAM_RESTRICTION_ENABLED=true, cada usuário só pode acessar
    containers do seu time. Configure os arrays TEAM_*_USERS e TEAM_*_CONTAINERS
    no arquivo de configuração.

    Exemplo:
        daniel.oliveira no time ADMINISTRATIVO só acessa administrativo-*
        sidriao.neto no time VEICULO só acessa veiculo-*

EOF
}

show_version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo "DevOps - DETRAN-CE"
    echo "Ambiente: $ENVIRONMENT"
}

#===============================================================================
# PARSER DE ARGUMENTOS
#===============================================================================

parse_args() {
    COMMAND=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            -e|--env)
                CMD_ENVIRONMENT="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -V|--version)
                show_version
                exit 0
                ;;
            --user)
                CMD_USER="$2"
                shift 2
                ;;
            --hours)
                CMD_HOURS="$2"
                shift 2
                ;;
            --exec)
                CMD_EXEC=true
                shift
                ;;
            --webconf)
                CMD_WEBCONF=true
                shift
                ;;
            --days)
                CMD_DAYS="$2"
                shift 2
                ;;
            --format)
                CMD_FORMAT="$2"
                shift 2
                ;;
            --reason)
                CMD_REASON="$2"
                shift 2
                ;;
            --approver)
                CMD_APPROVER="$2"
                shift 2
                ;;
            --request-id)
                CMD_REQUEST_ID="$2"
                shift 2
                ;;
            --remove-home)
                CMD_REMOVE_HOME=true
                shift
                ;;
            -*)
                log_error "Opção desconhecida: $1"
                echo "Use -h para ajuda"
                exit 1
                ;;
            *)
                COMMAND="$1"
                shift
                ;;
        esac
    done
    
    # Comando padrão
    [[ -z "$COMMAND" ]] && COMMAND="status"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Parse argumentos
    parse_args "$@"
    
    # Verifica root (exceto para help e version)
    check_root "$@"
    
    # Verifica dependências
    check_dependencies
    
    # Carrega configuração
    if ! load_config "$CONFIG_FILE"; then
        log_error "Falha ao carregar configuração"
        exit 1
    fi
    
    # Executa comando
    case "$COMMAND" in
        apply)           cmd_apply ;;
        remove)          cmd_remove ;;
        status)          show_status ;;
        dashboard)       show_dashboard ;;
        validate)        
            if load_config "$CONFIG_FILE"; then
                log_ok "Configuração válida"
            else
                log_error "Configuração inválida"
                exit 1
            fi
            ;;
        add-user)        cmd_add_user ;;
        remove-user)     cmd_remove_user ;;
        reset-user)      cmd_reset_user ;;
        delete-user)     cmd_delete_user ;;
        promote)         cmd_promote ;;
        demote)          cmd_demote ;;
        grant-temp)      cmd_grant_temp ;;
        revoke-temp)     cmd_revoke_temp ;;
        list-users)      cmd_list_users ;;
        request)         cmd_request ;;
        approve)         cmd_approve ;;
        deny)            cmd_deny ;;
        list-requests)   list_requests ;;
        audit-report)    generate_audit_report "$CMD_DAYS" "$CMD_USER" "$CMD_FORMAT" ;;
        audit-tail)      
            if [[ -f "$AUDIT_LOG_FILE" ]]; then
                tail -f "$AUDIT_LOG_FILE"
            else
                log_error "Arquivo de auditoria não existe: $AUDIT_LOG_FILE"
            fi
            ;;
        session-report)  session_report "$CMD_USER" "$CMD_DAYS" ;;
        health-check)    health_check ;;
        inactive-users)  list_inactive_users "$CMD_DAYS" ;;
        cleanup)         
            cleanup_expired_access
            revoke_inactive_users "$INACTIVITY_DAYS"
            ;;
        backup)          create_backup ;;
        list-backups)    list_backups ;;
        restore-backup)  restore_backup "$CMD_USER" ;;
        send-report)     send_report ;;
        generate-html)   generate_dashboard_html "$DASHBOARD_DIR/index.html" ;;
        sync)            sync_group_members ;;
        list-orphans)    list_orphan_users ;;
        cleanup-users)   cleanup_orphan_users ;;
        *)
            log_error "Comando desconhecido: $COMMAND"
            echo "Use -h para ajuda"
            exit 1
            ;;
    esac
}

#===============================================================================
# GERAÇÃO DE DASHBOARD HTML
#===============================================================================

generate_dashboard_html() {
    local output_file="${1:-/var/www/html/devs-dashboard/index.html}"
    local output_dir
    output_dir=$(dirname "$output_file")
    
    log_info "Gerando dashboard HTML: $output_file"
    
    mkdir -p "$output_dir" 2>/dev/null || true
    
    # Coleta dados
    local total_users=0 exec_users=0 webconf_users=0 temp_count=0 req_count=0
    
    if group_exists "$GRUPO_DEV"; then
        local members
        members=$(getent group "$GRUPO_DEV" | cut -d: -f4)
        [[ -n "$members" ]] && total_users=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    if group_exists "$GRUPO_DEV_EXEC"; then
        local members
        members=$(getent group "$GRUPO_DEV_EXEC" | cut -d: -f4)
        [[ -n "$members" ]] && exec_users=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    if group_exists "$GRUPO_DEV_WEBCONF"; then
        local members
        members=$(getent group "$GRUPO_DEV_WEBCONF" | cut -d: -f4)
        [[ -n "$members" ]] && webconf_users=$(echo "$members" | tr ',' '\n' | wc -l)
    fi
    
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        temp_count=$(find "$TEMP_ACCESS_DIR" -name "*.expiry" 2>/dev/null | wc -l)
    fi
    
    if [[ -d "$REQUESTS_DIR" ]]; then
        req_count=$(find "$REQUESTS_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l)
    fi
    
    # Gera JSON de usuários
    local users_json="["
    local first=true
    
    for group in "$GRUPO_DEV"; do
        group_exists "$group" || continue
        local members
        members=$(getent group "$group" | cut -d: -f4)
        
        IFS=',' read -ra users <<< "$members"
        for user in "${users[@]}"; do
            [[ -z "$user" ]] && continue
            
            [[ "$first" != true ]] && users_json+=","
            first=false
            
            local has_exec="false" has_webconf="false"
            user_in_group "$user" "$GRUPO_DEV_EXEC" && has_exec="true"
            user_in_group "$user" "$GRUPO_DEV_WEBCONF" && has_webconf="true"
            
            local team_name="null" containers="\"*\""
            if user_team=$(get_user_team "$user" 2>/dev/null); then
                team_name="\"$user_team\""
                local team_containers
                team_containers=$(get_team_containers "$user_team" | head -1)
                containers="\"$team_containers\""
            fi
            
            users_json+="{\"name\":\"$user\",\"basic\":true,\"exec\":$has_exec,\"webconf\":$has_webconf,\"team\":$team_name,\"containers\":$containers}"
        done
    done
    users_json+="]"
    
    # Gera JSON de times
    local teams_json="["
    first=true
    
    for team in "${TEAMS[@]}"; do
        local users_var="TEAM_${team}_USERS"
        local containers_var="TEAM_${team}_CONTAINERS"
        
        if declare -p "$users_var" &>/dev/null; then
            [[ "$first" != true ]] && teams_json+=","
            first=false
            
            local -a team_users team_containers
            eval "team_users=(\"\${${users_var}[@]}\")"
            eval "team_containers=(\"\${${containers_var}[@]}\")" 2>/dev/null || team_containers=()
            
            local users_list=""
            for u in "${team_users[@]}"; do
                [[ -n "$users_list" ]] && users_list+=","
                users_list+="\"$u\""
            done
            
            local containers_list=""
            for c in "${team_containers[@]}"; do
                [[ -n "$containers_list" ]] && containers_list+=","
                containers_list+="\"$c\""
            done
            
            teams_json+="{\"name\":\"$team\",\"containers\":[$containers_list],\"users\":[$users_list]}"
        fi
    done
    teams_json+="]"
    
    # Gera JSON de acessos temporários
    local temp_json="["
    first=true
    local now
    now=$(date +%s)
    
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
            [[ ! -f "$expiry_file" ]] && continue
            
            [[ "$first" != true ]] && temp_json+=","
            first=false
            
            local user
            user=$(basename "$expiry_file" .expiry)
            local expiry
            expiry=$(cat "$expiry_file")
            local remaining=$(( (expiry - now) / 3600 ))
            local reason=""
            [[ -f "${TEMP_ACCESS_DIR}/${user}.reason" ]] && reason=$(cat "${TEMP_ACCESS_DIR}/${user}.reason")
            
            temp_json+="{\"user\":\"$user\",\"hoursRemaining\":$remaining,\"totalHours\":4,\"reason\":\"$reason\"}"
        done
    fi
    temp_json+="]"
    
    # Gera JSON de solicitações
    local requests_json="["
    first=true
    
    if [[ -d "$REQUESTS_DIR" ]]; then
        for request_file in "$REQUESTS_DIR"/*.json; do
            [[ ! -f "$request_file" ]] && continue
            
            [[ "$first" != true ]] && requests_json+=","
            first=false
            
            local id user hours reason created
            id=$(grep -o '"id": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            user=$(grep -o '"user": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            hours=$(grep -o '"hours": *[0-9]*' "$request_file" | grep -o '[0-9]*')
            reason=$(grep -o '"reason": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            created=$(grep -o '"created_at": *"[^"]*"' "$request_file" | cut -d'"' -f4)
            
            requests_json+="{\"id\":\"$id\",\"user\":\"$user\",\"hours\":$hours,\"reason\":\"$reason\",\"createdAt\":\"$created\"}"
        done
    fi
    requests_json+="]"
    
    # Gera HTML
    cat > "$output_file" << HTMLEOF
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="60">
    <title>DevOps Permissions Dashboard - DETRAN-CE</title>
    <style>
        :root{--primary:#2563eb;--primary-dark:#1d4ed8;--success:#10b981;--warning:#f59e0b;--danger:#ef4444;--bg-dark:#0f172a;--bg-card:#1e293b;--bg-card-hover:#334155;--text-primary:#f1f5f9;--text-secondary:#94a3b8;--border:#334155}*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',system-ui,-apple-system,sans-serif;background:var(--bg-dark);color:var(--text-primary);min-height:100vh}.header{background:linear-gradient(135deg,var(--primary) 0%,var(--primary-dark) 100%);padding:20px 30px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 4px 20px rgba(0,0,0,0.3)}.header h1{font-size:1.5rem;font-weight:600}.env-badge{background:rgba(255,255,255,0.2);padding:5px 15px;border-radius:20px;font-size:0.85rem}.env-badge.production{background:var(--danger)}.env-badge.staging{background:var(--warning)}.env-badge.development{background:var(--success)}.container{max-width:1400px;margin:0 auto;padding:30px}.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:20px;margin-bottom:30px}.stat-card{background:var(--bg-card);border-radius:12px;padding:20px;border:1px solid var(--border)}.stat-card .icon{width:50px;height:50px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:1.5rem;margin-bottom:15px}.stat-card .icon.blue{background:rgba(37,99,235,0.2)}.stat-card .icon.green{background:rgba(16,185,129,0.2)}.stat-card .icon.yellow{background:rgba(245,158,11,0.2)}.stat-card .icon.red{background:rgba(239,68,68,0.2)}.stat-card .icon.purple{background:rgba(139,92,246,0.2)}.stat-card .value{font-size:2rem;font-weight:700;margin-bottom:5px}.stat-card .label{color:var(--text-secondary);font-size:0.9rem}.main-grid{display:grid;grid-template-columns:2fr 1fr;gap:30px}@media(max-width:1024px){.main-grid{grid-template-columns:1fr}}.card{background:var(--bg-card);border-radius:12px;border:1px solid var(--border);overflow:hidden;margin-bottom:20px}.card-header{padding:20px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center}.card-header h2{font-size:1.1rem;font-weight:600}.card-body{padding:20px}.table{width:100%;border-collapse:collapse}.table th,.table td{padding:12px 15px;text-align:left;border-bottom:1px solid var(--border)}.table th{background:rgba(0,0,0,0.2);font-weight:600;font-size:0.85rem;text-transform:uppercase;color:var(--text-secondary)}.table tr:hover{background:var(--bg-card-hover)}.badge{display:inline-flex;padding:4px 10px;border-radius:20px;font-size:0.75rem;font-weight:600}.badge-success{background:rgba(16,185,129,0.2);color:var(--success)}.badge-warning{background:rgba(245,158,11,0.2);color:var(--warning)}.check{color:var(--success)}.cross{color:var(--danger)}.team-badge{background:linear-gradient(135deg,#6366f1 0%,#8b5cf6 100%);color:white;padding:3px 10px;border-radius:4px;font-size:0.75rem}.teams-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:15px}.team-card{background:rgba(0,0,0,0.2);border-radius:8px;padding:15px;border-left:4px solid var(--primary)}.team-name{font-weight:600;margin-bottom:8px}.team-containers{font-family:monospace;font-size:0.85rem;color:var(--text-secondary);margin-bottom:10px}.team-users{display:flex;flex-wrap:wrap;gap:5px}.team-user-badge{background:rgba(255,255,255,0.1);padding:3px 8px;border-radius:4px;font-size:0.8rem}.temp-access-item{display:flex;justify-content:space-between;align-items:center;padding:12px 15px;background:rgba(0,0,0,0.2);border-radius:8px;margin-bottom:10px}.request-card{background:rgba(245,158,11,0.1);border:1px solid rgba(245,158,11,0.3);border-radius:8px;padding:15px;margin-bottom:10px}.footer{text-align:center;padding:30px;color:var(--text-secondary);font-size:0.85rem}.empty-state{text-align:center;padding:40px;color:var(--text-secondary)}.empty-state-icon{font-size:3rem;margin-bottom:15px;opacity:0.5}
    </style>
</head>
<body>
    <header class="header">
        <h1>🖥️ DevOps Permissions Dashboard</h1>
        <div style="display:flex;align-items:center;gap:15px">
            <span class="env-badge $ENVIRONMENT">$ENVIRONMENT</span>
            <span>Atualizado: $(_ts)</span>
        </div>
    </header>
    
    <div class="container">
        <div class="stats-grid">
            <div class="stat-card"><div class="icon blue">👥</div><div class="value">$total_users</div><div class="label">Usuários Ativos</div></div>
            <div class="stat-card"><div class="icon green">🔑</div><div class="value">$exec_users</div><div class="label">Com Acesso Exec</div></div>
            <div class="stat-card"><div class="icon purple">⚙️</div><div class="value">$webconf_users</div><div class="label">Com Acesso WebConf</div></div>
            <div class="stat-card"><div class="icon yellow">⏱️</div><div class="value">$temp_count</div><div class="label">Acessos Temporários</div></div>
            <div class="stat-card"><div class="icon red">📋</div><div class="value">$req_count</div><div class="label">Solicitações</div></div>
        </div>
        
        <div class="main-grid">
            <div>
                <div class="card">
                    <div class="card-header"><h2>👥 Usuários e Permissões</h2></div>
                    <div class="card-body" style="padding:0">
                        <table class="table">
                            <thead><tr><th>Usuário</th><th>Básico</th><th>Exec</th><th>WebConf</th><th>Time</th><th>Containers</th></tr></thead>
                            <tbody id="usersTable"></tbody>
                        </table>
                    </div>
                </div>
                <div class="card">
                    <div class="card-header"><h2>🏢 Times / Projetos</h2><span class="badge badge-${TEAM_RESTRICTION_ENABLED:+success}">${TEAM_RESTRICTION_ENABLED}</span></div>
                    <div class="card-body"><div class="teams-grid" id="teamsGrid"></div></div>
                </div>
            </div>
            <div>
                <div class="card">
                    <div class="card-header"><h2>⏱️ Acessos Temporários</h2></div>
                    <div class="card-body" id="tempAccessList"></div>
                </div>
                <div class="card">
                    <div class="card-header"><h2>📋 Solicitações Pendentes</h2></div>
                    <div class="card-body" id="requestsList"></div>
                </div>
            </div>
        </div>
    </div>
    
    <footer class="footer">DevOps Permissions Manager v$SCRIPT_VERSION | DETRAN-CE | Gerado: $(_ts)</footer>
    
    <script>
        const data = {
            users: $users_json,
            teams: $teams_json,
            tempAccess: $temp_json,
            requests: $requests_json
        };
        
        document.getElementById('usersTable').innerHTML = data.users.map(u => 
            '<tr><td><strong>'+u.name+'</strong></td><td>'+(u.basic?'<span class="check">✓</span>':'<span class="cross">✗</span>')+'</td><td>'+(u.exec?'<span class="check">✓</span>':'<span class="cross">✗</span>')+'</td><td>'+(u.webconf?'<span class="check">✓</span>':'<span class="cross">✗</span>')+'</td><td>'+(u.team?'<span class="team-badge">'+u.team+'</span>':'-')+'</td><td><code>'+u.containers+'</code></td></tr>'
        ).join('');
        
        document.getElementById('teamsGrid').innerHTML = data.teams.length ? data.teams.map(t =>
            '<div class="team-card"><div class="team-name">🏢 '+t.name+'</div><div class="team-containers">📦 '+t.containers.join(', ')+'</div><div class="team-users">'+(t.users.length?t.users.map(u=>'<span class="team-user-badge">👤 '+u+'</span>').join(''):'<span style="color:var(--text-secondary)">Nenhum usuário</span>')+'</div></div>'
        ).join('') : '<div class="empty-state"><div class="empty-state-icon">🔓</div><p>Sem restrição por time</p></div>';
        
        document.getElementById('tempAccessList').innerHTML = data.tempAccess.length ? data.tempAccess.map(a =>
            '<div class="temp-access-item"><div><strong>'+a.user+'</strong><br><small>'+a.reason+'</small></div><div style="font-family:monospace;font-size:1.2rem;font-weight:bold">'+a.hoursRemaining+'h</div></div>'
        ).join('') : '<div class="empty-state"><div class="empty-state-icon">⏱️</div><p>Nenhum acesso temporário</p></div>';
        
        document.getElementById('requestsList').innerHTML = data.requests.length ? data.requests.map(r =>
            '<div class="request-card"><div style="display:flex;justify-content:space-between"><code>'+r.id+'</code><span class="badge badge-warning">Pendente</span></div><p style="margin:10px 0"><strong>'+r.user+'</strong> solicita <strong>'+r.hours+'h</strong></p><small>📝 '+r.reason+'</small></div>'
        ).join('') : '<div class="empty-state"><div class="empty-state-icon">📋</div><p>Nenhuma solicitação</p></div>';
    </script>
</body>
</html>
HTMLEOF
    
    chmod 644 "$output_file"
    log_ok "Dashboard gerado: $output_file"
}

#===============================================================================
# EXECUÇÃO
#===============================================================================

# Só executa se for o script principal (não se for source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
