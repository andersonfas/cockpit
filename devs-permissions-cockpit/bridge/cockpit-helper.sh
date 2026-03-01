#!/usr/bin/env bash
#===============================================================================
#
#   ARQUIVO: cockpit-helper.sh
#   DESCRIÇÃO: Bridge entre o plugin Cockpit e o devs_permissions_manager.sh
#              Retorna dados estruturados em JSON para consumo do frontend.
#
#   INSTALAÇÃO: /usr/libexec/devs-permissions/cockpit-helper.sh
#
#   SEGURANÇA: Este script é executado via cockpit.spawn() com superuser.
#              Todas as entradas são sanitizadas antes de passar ao manager.
#
#===============================================================================

set -o nounset
set -o pipefail

readonly HELPER_VERSION="1.0.0"
readonly MANAGER_SCRIPT="/usr/libexec/devs-permissions/devs_permissions_manager.sh"
readonly CONFIG_FILE="/etc/devs-permissions/devs_permissions.conf"

# Caminhos de dados (devem corresponder ao manager)
readonly TEMP_ACCESS_DIR="/var/lib/devs_permissions/temp_access"
readonly REQUESTS_DIR="/var/lib/devs_permissions/requests"
readonly AUDIT_LOG_DIR="/var/log/devs_audit"
readonly AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/docker_audit.log"
readonly BACKUP_DIR="/var/backups/devs_permissions"

# Grupos padrão (podem ser sobrescritos pela config)
GRUPO_DEV="devs"
GRUPO_DEV_EXEC="devs_exec"
GRUPO_DEV_WEBCONF="devs_webconf"

#===============================================================================
# UTILIDADES
#===============================================================================

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

json_string() {
    printf '"%s"' "$(json_escape "$1")"
}

sanitize_input() {
    local input="$1"
    # Remove caracteres perigosos, permite alfanuméricos, ponto, hífen, underscore
    echo "$input" | sed 's/[^a-zA-Z0-9._-]//g'
}

sanitize_reason() {
    local input="$1"
    # Para motivos, permite mais caracteres mas remove aspas e backticks
    echo "$input" | sed "s/['\"\`\$]//g" | head -c 200
}

load_config_vars() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local val
        val=$(grep -m1 '^GRUPO_DEV=' "$CONFIG_FILE" 2>/dev/null | sed 's/^GRUPO_DEV="\?\([^"]*\)"\?/\1/')
        [[ -n "$val" ]] && GRUPO_DEV="$val"
        val=$(grep -m1 '^GRUPO_DEV_EXEC=' "$CONFIG_FILE" 2>/dev/null | sed 's/^GRUPO_DEV_EXEC="\?\([^"]*\)"\?/\1/')
        [[ -n "$val" ]] && GRUPO_DEV_EXEC="$val"
        val=$(grep -m1 '^GRUPO_DEV_WEBCONF=' "$CONFIG_FILE" 2>/dev/null | sed 's/^GRUPO_DEV_WEBCONF="\?\([^"]*\)"\?/\1/')
        [[ -n "$val" ]] && GRUPO_DEV_WEBCONF="$val"
    fi
}

get_group_members() {
    local group="$1"
    local members
    members=$(getent group "$group" 2>/dev/null | cut -d: -f4)
    echo "$members"
}

epoch_now() {
    date '+%s'
}

#===============================================================================
# COMANDOS - DADOS PARA DASHBOARD
#===============================================================================

cmd_get_overview() {
    load_config_vars

    local basic_members exec_members webconf_members
    basic_members=$(get_group_members "$GRUPO_DEV")
    exec_members=$(get_group_members "$GRUPO_DEV_EXEC")
    webconf_members=$(get_group_members "$GRUPO_DEV_WEBCONF")

    local basic_count=0 exec_count=0 webconf_count=0
    [[ -n "$basic_members" ]] && basic_count=$(echo "$basic_members" | tr ',' '\n' | grep -c . || true)
    [[ -n "$exec_members" ]] && exec_count=$(echo "$exec_members" | tr ',' '\n' | grep -c . || true)
    [[ -n "$webconf_members" ]] && webconf_count=$(echo "$webconf_members" | tr ',' '\n' | grep -c . || true)

    local temp_count=0 pending_count=0
    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        temp_count=$(find "$TEMP_ACCESS_DIR" -name "*.expiry" -type f 2>/dev/null | wc -l)
    fi
    if [[ -d "$REQUESTS_DIR" ]]; then
        pending_count=$(find "$REQUESTS_DIR" -name "*.json" -type f 2>/dev/null | while read -r f; do
            grep -l '"status".*"pending"' "$f" 2>/dev/null
        done | wc -l)
    fi

    # Extrair dados da config
    local environment="unknown" team_count=0
    if [[ -f "$CONFIG_FILE" ]]; then
        environment=$(grep -m1 '^ENVIRONMENT=' "$CONFIG_FILE" 2>/dev/null | sed 's/^ENVIRONMENT="\?\([^"]*\)"\?/\1/' || echo "unknown")
        # Contar times
        local teams_line
        teams_line=$(sed -n '/^TEAMS=(/,/)/p' "$CONFIG_FILE" 2>/dev/null | grep '"' | wc -l)
        team_count=$teams_line
    fi

    cat <<EOF
{
    "status": "ok",
    "environment": $(json_string "$environment"),
    "counts": {
        "basic": $basic_count,
        "exec": $exec_count,
        "webconf": $webconf_count,
        "temp_access": $temp_count,
        "pending_requests": $pending_count,
        "teams": $team_count
    },
    "groups": {
        "basic": $(json_string "$basic_members"),
        "exec": $(json_string "$exec_members"),
        "webconf": $(json_string "$webconf_members")
    }
}
EOF
}

#===============================================================================
# COMANDOS - LISTAR USUÁRIOS DETALHADOS
#===============================================================================

cmd_list_users() {
    load_config_vars

    local basic_members exec_members webconf_members
    basic_members=$(get_group_members "$GRUPO_DEV")
    exec_members=$(get_group_members "$GRUPO_DEV_EXEC")
    webconf_members=$(get_group_members "$GRUPO_DEV_WEBCONF")

    # Coletar todos os usuários únicos
    local all_users=""
    [[ -n "$basic_members" ]] && all_users="$basic_members"
    if [[ -n "$exec_members" ]]; then
        [[ -n "$all_users" ]] && all_users="${all_users},${exec_members}" || all_users="$exec_members"
    fi
    if [[ -n "$webconf_members" ]]; then
        [[ -n "$all_users" ]] && all_users="${all_users},${webconf_members}" || all_users="$webconf_members"
    fi

    # Deduplica
    local unique_users
    unique_users=$(echo "$all_users" | tr ',' '\n' | sort -u | grep -v '^$')

    # Ler times da config
    local teams_data="{}"
    if [[ -f "$CONFIG_FILE" ]]; then
        # Extrair times e seus membros
        local teams
        teams=$(sed -n '/^TEAMS=(/,/)/p' "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')

        local teams_json="{"
        local first_team=true
        while IFS= read -r team; do
            [[ -z "$team" ]] && continue
            [[ "$first_team" != true ]] && teams_json+=","
            first_team=false

            local team_users
            team_users=$(sed -n "/^TEAM_${team}_USERS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')

            local team_containers
            team_containers=$(sed -n "/^TEAM_${team}_CONTAINERS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')

            teams_json+="$(json_string "$team"):{\"users\":$(json_string "$team_users"),\"containers\":$(json_string "$team_containers")}"
        done <<< "$teams"
        teams_json+="}"
        teams_data="$teams_json"
    fi

    # Construir array JSON de usuários
    local json='{"status":"ok","users":['
    local first=true

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        [[ "$first" != true ]] && json+=","
        first=false

        local is_basic=false is_exec=false is_webconf=false
        echo ",$basic_members," | grep -q ",$user," && is_basic=true
        echo ",$exec_members," | grep -q ",$user," && is_exec=true
        echo ",$webconf_members," | grep -q ",$user," && is_webconf=true

        # Buscar time do usuário
        local user_teams=""
        if [[ -f "$CONFIG_FILE" ]]; then
            local teams
            teams=$(sed -n '/^TEAMS=(/,/)/p' "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')
            while IFS= read -r team; do
                [[ -z "$team" ]] && continue
                if sed -n "/^TEAM_${team}_USERS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep -q "\"$user\""; then
                    [[ -n "$user_teams" ]] && user_teams="${user_teams},"
                    user_teams="${user_teams}${team}"
                fi
            done <<< "$teams"
        fi

        # Verificar temp access (formato: .expiry contém epoch, .reason contém texto)
        local has_temp=false temp_expires="" temp_reason=""
        if [[ -d "$TEMP_ACCESS_DIR" ]]; then
            local expiry_file="${TEMP_ACCESS_DIR}/${user}.expiry"
            local reason_file="${TEMP_ACCESS_DIR}/${user}.reason"
            if [[ -f "$expiry_file" ]]; then
                has_temp=true
                temp_expires=$(cat "$expiry_file" 2>/dev/null || echo "0")
                [[ -f "$reason_file" ]] && temp_reason=$(cat "$reason_file" 2>/dev/null || echo "")
            fi
        fi

        # Última atividade
        local last_login=""
        last_login=$(lastlog -u "$user" 2>/dev/null | tail -1 | awk '{if ($2 != "**Never") print $4,$5,$6,$7,$9; else print "never"}' || echo "unknown")

        json+="{\"name\":$(json_string "$user")"
        json+=",\"basic\":${is_basic},\"exec\":${is_exec},\"webconf\":${is_webconf}"
        json+=",\"teams\":$(json_string "$user_teams")"
        json+=",\"has_temp\":${has_temp}"
        json+=",\"temp_expires\":$(json_string "$temp_expires")"
        json+=",\"temp_reason\":$(json_string "$temp_reason")"
        json+=",\"last_login\":$(json_string "$last_login")"
        json+="}"
    done <<< "$unique_users"

    json+=']}'
    echo "$json"
}

#===============================================================================
# COMANDOS - ACESSO TEMPORÁRIO
#===============================================================================

cmd_list_temp_access() {
    local json='{"status":"ok","entries":['
    local first=true
    local now
    now=$(epoch_now)

    if [[ -d "$TEMP_ACCESS_DIR" ]]; then
        for expiry_file in "$TEMP_ACCESS_DIR"/*.expiry; do
            [[ -f "$expiry_file" ]] || continue
            [[ "$first" != true ]] && json+=","
            first=false

            local user expiry reason=""
            user=$(basename "$expiry_file" .expiry)
            expiry=$(cat "$expiry_file" 2>/dev/null || echo "0")
            local reason_file="${TEMP_ACCESS_DIR}/${user}.reason"
            [[ -f "$reason_file" ]] && reason=$(cat "$reason_file" 2>/dev/null || echo "")

            local remaining=$(( (expiry - now) / 3600 ))
            json+="{\"user\":$(json_string "$user"),\"expires_epoch\":$expiry,\"hours_remaining\":$remaining,\"reason\":$(json_string "$reason")}"
        done
    fi

    json+='],"now":'"$now"'}'
    echo "$json"
}

#===============================================================================
# COMANDOS - SOLICITAÇÕES
#===============================================================================

cmd_list_requests() {
    local json='{"status":"ok","requests":['
    local first=true

    if [[ -d "$REQUESTS_DIR" ]]; then
        for f in "$REQUESTS_DIR"/*.json; do
            [[ -f "$f" ]] || continue
            [[ "$first" != true ]] && json+=","
            first=false

            local content
            content=$(cat "$f" 2>/dev/null || echo "{}")
            json+="$content"
        done
    fi

    json+=']}'
    echo "$json"
}

#===============================================================================
# COMANDOS - TIMES
#===============================================================================

cmd_list_teams() {
    local json='{"status":"ok","teams":['
    local first=true

    if [[ -f "$CONFIG_FILE" ]]; then
        local teams
        teams=$(sed -n '/^TEAMS=(/,/)/p' "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')

        while IFS= read -r team; do
            [[ -z "$team" ]] && continue
            [[ "$first" != true ]] && json+=","
            first=false

            local users containers webconf_patterns
            users=$(sed -n "/^TEAM_${team}_USERS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')
            containers=$(sed -n "/^TEAM_${team}_CONTAINERS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')
            webconf_patterns=$(sed -n "/^TEAM_${team}_WEBCONF_PATTERNS=(/,/)/p" "$CONFIG_FILE" 2>/dev/null | grep '"' | sed 's/.*"\(.*\)".*/\1/')

            # Converter para arrays JSON
            local users_arr='['
            local uf=true
            while IFS= read -r u; do
                [[ -z "$u" ]] && continue
                [[ "$uf" != true ]] && users_arr+=","
                uf=false
                users_arr+="$(json_string "$u")"
            done <<< "$users"
            users_arr+=']'

            local cont_arr='['
            local cf=true
            while IFS= read -r c; do
                [[ -z "$c" ]] && continue
                [[ "$cf" != true ]] && cont_arr+=","
                cf=false
                cont_arr+="$(json_string "$c")"
            done <<< "$containers"
            cont_arr+=']'

            local wc_arr='['
            local wf=true
            while IFS= read -r w; do
                [[ -z "$w" ]] && continue
                [[ "$wf" != true ]] && wc_arr+=","
                wf=false
                wc_arr+="$(json_string "$w")"
            done <<< "$webconf_patterns"
            wc_arr+=']'

            json+="{\"name\":$(json_string "$team"),\"users\":${users_arr},\"containers\":${cont_arr},\"webconf_patterns\":${wc_arr}}"
        done <<< "$teams"
    fi

    json+=']}'
    echo "$json"
}

#===============================================================================
# COMANDOS - BACKUPS
#===============================================================================

cmd_list_backups() {
    local json='{"status":"ok","backups":['
    local first=true

    if [[ -d "$BACKUP_DIR" ]]; then
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            [[ "$first" != true ]] && json+=","
            first=false

            local size
            size=$(echo "$entry" | awk '{print $1}')
            local path
            path=$(echo "$entry" | awk '{print $2}')
            local name
            name=$(basename "$path")

            json+="{\"name\":$(json_string "$name"),\"size\":$(json_string "$size"),\"path\":$(json_string "$path")}"
        done < <(du -sh "$BACKUP_DIR"/* 2>/dev/null | sort -rh | head -20)
    fi

    json+=']}'
    echo "$json"
}

#===============================================================================
# COMANDOS - CONFIGURAÇÃO
#===============================================================================

cmd_get_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local content
        content=$(cat "$CONFIG_FILE")
        local json='{"status":"ok","path":'
        json+="$(json_string "$CONFIG_FILE")"
        json+=',"content":'
        json+="$(json_string "$content")"
        json+='}'
        echo "$json"
    else
        echo '{"status":"error","message":"Config file not found","path":"'"$CONFIG_FILE"'"}'
    fi
}

cmd_save_config() {
    local content="$1"
    if [[ -z "$content" ]]; then
        echo '{"status":"error","message":"No content provided"}'
        return 1
    fi

    # Backup antes de salvar
    if [[ -f "$CONFIG_FILE" ]]; then
        local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_file" 2>/dev/null || true
    fi

    echo "$content" > "$CONFIG_FILE"
    echo '{"status":"ok","message":"Configuration saved"}'
}

#===============================================================================
# COMANDOS - EXECUTAR MANAGER (proxy seguro)
#===============================================================================

cmd_run_manager() {
    # Executa o manager com os argumentos recebidos e captura output
    if [[ ! -x "$MANAGER_SCRIPT" ]]; then
        echo '{"status":"error","message":"Manager script not found or not executable"}'
        return 1
    fi

    # Sanitiza argumentos: usernames e valores que vão para o manager
    local sanitized_args=("--force" "--config" "$CONFIG_FILE")
    local expect_user=false expect_reason=false expect_hours=false
    for arg in "$@"; do
        if [[ "$expect_user" == true ]]; then
            sanitized_args+=("$(sanitize_input "$arg")")
            expect_user=false
        elif [[ "$expect_reason" == true ]]; then
            sanitized_args+=("$(sanitize_reason "$arg")")
            expect_reason=false
        elif [[ "$expect_hours" == true ]]; then
            # Só aceita números
            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                sanitized_args+=("$arg")
            else
                echo '{"status":"error","message":"Invalid hours value"}'
                return 1
            fi
            expect_hours=false
        else
            case "$arg" in
                --user|-u)  sanitized_args+=("$arg"); expect_user=true ;;
                --reason)   sanitized_args+=("$arg"); expect_reason=true ;;
                --hours|-H) sanitized_args+=("$arg"); expect_hours=true ;;
                -*)         sanitized_args+=("$arg") ;;
                *)          sanitized_args+=("$(sanitize_input "$arg")") ;;
            esac
        fi
    done

    local args=("${sanitized_args[@]}")

    local output exit_code
    output=$("$MANAGER_SCRIPT" "${args[@]}" 2>&1) && exit_code=$? || exit_code=$?

    # Strip ANSI color codes
    output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    cat <<EOF
{"status":"$([ $exit_code -eq 0 ] && echo "ok" || echo "error")","exit_code":$exit_code,"output":$(json_string "$output")}
EOF
}

#===============================================================================
# COMANDOS - VERIFICAÇÃO DE INSTALAÇÃO
#===============================================================================

cmd_check_install() {
    local manager_ok=false config_ok=false
    local manager_version=""

    [[ -x "$MANAGER_SCRIPT" ]] && manager_ok=true
    [[ -f "$CONFIG_FILE" ]] && config_ok=true

    if [[ "$manager_ok" == true ]]; then
        manager_version=$("$MANAGER_SCRIPT" --version 2>/dev/null | head -1 || echo "unknown")
    fi

    cat <<EOF
{
    "status": "ok",
    "helper_version": "$HELPER_VERSION",
    "manager_installed": $manager_ok,
    "manager_version": $(json_string "$manager_version"),
    "config_exists": $config_ok,
    "config_path": $(json_string "$CONFIG_FILE"),
    "manager_path": $(json_string "$MANAGER_SCRIPT")
}
EOF
}

#===============================================================================
# DISPATCHER
#===============================================================================

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        get-overview)      cmd_get_overview ;;
        list-users)        cmd_list_users ;;
        list-teams)        cmd_list_teams ;;
        list-temp-access)  cmd_list_temp_access ;;
        list-requests)     cmd_list_requests ;;
        list-backups)      cmd_list_backups ;;
        get-config)        cmd_get_config ;;
        save-config)       cmd_save_config "$*" ;;
        check-install)     cmd_check_install ;;

        # Proxy para o manager (todas as ações de escrita)
        run)               cmd_run_manager "$@" ;;

        *)
            echo '{"status":"error","message":"Unknown command: '"$(json_escape "$command")"'"}'
            exit 1
            ;;
    esac
}

main "$@"
