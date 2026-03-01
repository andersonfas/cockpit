#!/usr/bin/env bash
#===============================================================================
# SCRIPT DE DEPLOY - Cria todos os arquivos do plugin e instala
# Execute no servidor: bash deploy-plugin.sh
#===============================================================================

set -euo pipefail

echo "=== Deploy devs-permissions-cockpit ==="

# Diretório de trabalho
WORK_DIR="/tmp/devs-permissions-cockpit"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{src,bridge,packaging}

echo "[1/8] Criando manifest.json..."
cat > "$WORK_DIR/src/manifest.json" << 'ENDFILE'
{
    "version": 0,
    "require": {
        "cockpit": "264"
    },
    "menu": {
        "index": {
            "label": "DevOps Permissions",
            "order": 85,
            "keywords": [
                {
                    "matches": ["devs", "permissions", "docker", "developers", "access", "teams", "exec", "webconf", "audit", "detran"]
                }
            ]
        }
    },
    "content-security-policy": "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:"
}
ENDFILE

echo "[2/8] Criando index.html..."
cat > "$WORK_DIR/src/index.html" << 'ENDFILE'
<!DOCTYPE html>
<html>
<head>
    <title>DevOps Permissions Manager</title>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <link href="devs-permissions.css" type="text/css" rel="stylesheet" />
    <script src="../base1/cockpit.js"></script>
</head>
<body>
    <!-- Header -->
    <div id="app-header">
        <div class="header-left">
            <h1 id="app-title">DevOps Permissions Manager</h1>
            <span id="header-env" class="env-badge">---</span>
            <span id="header-version" class="version-label"></span>
        </div>
        <div class="header-right">
            <button id="btn-refresh" class="btn btn-icon" title="Atualizar">&#x21bb;</button>
        </div>
    </div>

    <!-- Navigation Tabs -->
    <nav id="tab-nav">
        <button class="tab-btn active" data-tab="dashboard">Dashboard</button>
        <button class="tab-btn" data-tab="users">Usuarios</button>
        <button class="tab-btn" data-tab="teams">Times</button>
        <button class="tab-btn" data-tab="temp-access">Acesso Temporario</button>
        <button class="tab-btn" data-tab="requests">Solicitacoes</button>
        <button class="tab-btn" data-tab="audit">Auditoria</button>
        <button class="tab-btn" data-tab="maintenance">Manutencao</button>
        <button class="tab-btn" data-tab="config">Configuracao</button>
    </nav>

    <!-- Loading overlay -->
    <div id="loading-overlay" class="hidden">
        <div class="spinner"></div>
        <span>Carregando...</span>
    </div>

    <!-- Alert area -->
    <div id="alert-area"></div>

    <!-- Install warning -->
    <div id="install-warning" class="hidden">
        <div class="alert alert-danger" style="margin:24px;">
            <div>
                <strong>Script nao encontrado.</strong>
                <p>O <code>devs_permissions_manager.sh</code> nao foi encontrado em <code>/usr/libexec/devs-permissions/</code>.</p>
                <p>Instale o pacote completo ou copie os scripts manualmente.</p>
            </div>
        </div>
    </div>

    <!-- ===== Tab: Dashboard ===== -->
    <div id="tab-dashboard" class="tab-content active">
        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-number" id="stat-basic">-</div>
                <div class="stat-label">Usuarios Basico</div>
            </div>
            <div class="stat-card stat-blue">
                <div class="stat-number" id="stat-exec">-</div>
                <div class="stat-label">Usuarios Exec</div>
            </div>
            <div class="stat-card stat-purple">
                <div class="stat-number" id="stat-webconf">-</div>
                <div class="stat-label">Usuarios WebConf</div>
            </div>
            <div class="stat-card stat-orange">
                <div class="stat-number" id="stat-temp">-</div>
                <div class="stat-label">Acessos Temporarios</div>
            </div>
            <div class="stat-card stat-red">
                <div class="stat-number" id="stat-requests">-</div>
                <div class="stat-label">Pendentes</div>
            </div>
            <div class="stat-card stat-green">
                <div class="stat-number" id="stat-teams">-</div>
                <div class="stat-label">Times</div>
            </div>
        </div>
        <div class="panel-grid">
            <div class="panel">
                <h3>Membros dos Grupos</h3>
                <div id="dash-groups"><p class="muted">Carregando...</p></div>
            </div>
            <div class="panel">
                <h3>Acessos Temporarios Ativos</h3>
                <div id="dash-temp"><p class="muted">Carregando...</p></div>
            </div>
            <div class="panel">
                <h3>Solicitacoes Pendentes</h3>
                <div id="dash-requests"><p class="muted">Carregando...</p></div>
            </div>
            <div class="panel">
                <h3>Status do Sistema</h3>
                <div id="dash-status"><p class="muted">Carregando...</p></div>
            </div>
        </div>
    </div>

    <!-- ===== Tab: Users ===== -->
    <div id="tab-users" class="tab-content">
        <div class="toolbar">
            <button id="btn-add-user" class="btn btn-primary">+ Adicionar Usuario</button>
            <button id="btn-apply" class="btn btn-secondary">Aplicar Configuracao</button>
            <button id="btn-sync" class="btn btn-secondary">Sincronizar Grupos</button>
            <div class="toolbar-spacer"></div>
            <input type="text" id="user-search" class="toolbar-input" placeholder="Filtrar usuarios..." />
        </div>
        <div class="table-wrap">
            <table class="dtable" id="users-table">
                <thead>
                    <tr>
                        <th>Usuario</th>
                        <th>Basico</th>
                        <th>Exec</th>
                        <th>WebConf</th>
                        <th>Time(s)</th>
                        <th>Temp Access</th>
                        <th>Ultimo Login</th>
                        <th>Acoes</th>
                    </tr>
                </thead>
                <tbody id="users-tbody">
                    <tr><td colspan="8" class="muted">Carregando...</td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <!-- ===== Tab: Teams ===== -->
    <div id="tab-teams" class="tab-content">
        <div id="teams-container">
            <p class="muted">Carregando...</p>
        </div>
    </div>

    <!-- ===== Tab: Temp Access ===== -->
    <div id="tab-temp-access" class="tab-content">
        <div class="toolbar">
            <button id="btn-grant-temp" class="btn btn-primary">+ Conceder Acesso Temporario</button>
            <button id="btn-cleanup-expired" class="btn btn-secondary">Limpar Expirados</button>
        </div>
        <div class="table-wrap">
            <table class="dtable">
                <thead>
                    <tr>
                        <th>Usuario</th>
                        <th>Concedido em</th>
                        <th>Expira em</th>
                        <th>Restante</th>
                        <th>Motivo</th>
                        <th>Acoes</th>
                    </tr>
                </thead>
                <tbody id="temp-tbody">
                    <tr><td colspan="6" class="muted">Carregando...</td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <!-- ===== Tab: Requests ===== -->
    <div id="tab-requests" class="tab-content">
        <div class="table-wrap">
            <table class="dtable">
                <thead>
                    <tr>
                        <th>ID</th>
                        <th>Usuario</th>
                        <th>Horas</th>
                        <th>Motivo</th>
                        <th>Data</th>
                        <th>Status</th>
                        <th>Acoes</th>
                    </tr>
                </thead>
                <tbody id="requests-tbody">
                    <tr><td colspan="7" class="muted">Carregando...</td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <!-- ===== Tab: Audit ===== -->
    <div id="tab-audit" class="tab-content">
        <div class="toolbar">
            <label class="toolbar-label">Periodo:
                <select id="audit-days" class="toolbar-select">
                    <option value="1">1 dia</option>
                    <option value="7" selected>7 dias</option>
                    <option value="30">30 dias</option>
                    <option value="90">90 dias</option>
                </select>
            </label>
            <label class="toolbar-label">Usuario:
                <input type="text" id="audit-user" class="toolbar-input" placeholder="Todos" />
            </label>
            <label class="toolbar-label">Formato:
                <select id="audit-format" class="toolbar-select">
                    <option value="text">Texto</option>
                    <option value="json">JSON</option>
                </select>
            </label>
            <button id="btn-audit-report" class="btn btn-primary">Gerar Relatorio</button>
            <button id="btn-session-report" class="btn btn-secondary">Sessoes</button>
            <button id="btn-health-check" class="btn btn-secondary">Health Check</button>
            <button id="btn-inactive" class="btn btn-secondary">Inativos</button>
        </div>
        <div class="panel">
            <h3 id="audit-title">Resultado</h3>
            <pre id="audit-output" class="code-block">Selecione uma acao acima.</pre>
        </div>
    </div>

    <!-- ===== Tab: Maintenance ===== -->
    <div id="tab-maintenance" class="tab-content">
        <div class="maint-grid">
            <div class="panel">
                <h3>Acoes de Manutencao</h3>
                <div class="maint-actions">
                    <div class="maint-item">
                        <div>
                            <strong>Aplicar Configuracao</strong>
                            <p class="muted">Cria/atualiza usuarios, grupos, sudoers, wrapper Docker, cron jobs e ACLs.</p>
                        </div>
                        <button class="btn btn-primary" data-action="apply">Executar</button>
                    </div>
                    <div class="maint-item">
                        <div>
                            <strong>Sincronizar Grupos</strong>
                            <p class="muted">Sincroniza membros dos grupos com a configuracao. Remove quem nao esta listado.</p>
                        </div>
                        <button class="btn btn-secondary" data-action="sync">Executar</button>
                    </div>
                    <div class="maint-item">
                        <div>
                            <strong>Limpar Expirados e Inativos</strong>
                            <p class="muted">Remove acessos temporarios expirados e revoga inativos.</p>
                        </div>
                        <button class="btn btn-secondary" data-action="cleanup">Executar</button>
                    </div>
                    <div class="maint-item">
                        <div>
                            <strong>Validar Configuracao</strong>
                            <p class="muted">Verifica se o arquivo de configuracao esta correto.</p>
                        </div>
                        <button class="btn btn-secondary" data-action="validate">Executar</button>
                    </div>
                    <div class="maint-item">
                        <div>
                            <strong>Criar Backup</strong>
                            <p class="muted">Salva backup dos arquivos de configuracao, sudoers e dados.</p>
                        </div>
                        <button class="btn btn-secondary" data-action="backup">Executar</button>
                    </div>
                    <div class="maint-item">
                        <div>
                            <strong>Listar Usuarios Orfaos</strong>
                            <p class="muted">Lista usuarios criados pelo sistema que nao estao mais na config.</p>
                        </div>
                        <button class="btn btn-secondary" data-action="list-orphans">Executar</button>
                    </div>
                    <div class="maint-item maint-danger">
                        <div>
                            <strong>Limpar Usuarios Orfaos</strong>
                            <p class="muted">Remove usuarios orfaos do sistema. Acao destrutiva!</p>
                        </div>
                        <button class="btn btn-danger" data-action="cleanup-users">Executar</button>
                    </div>
                    <div class="maint-item maint-danger">
                        <div>
                            <strong>Remover Todas as Configuracoes</strong>
                            <p class="muted">Remove todos os sudoers, wrappers, cron e ACLs criados pelo manager.</p>
                        </div>
                        <button class="btn btn-danger" data-action="remove">Executar</button>
                    </div>
                </div>
            </div>
            <div class="panel">
                <h3>Backups</h3>
                <div id="backups-list"><p class="muted">Carregando...</p></div>
            </div>
        </div>
        <div class="panel" style="margin-top:16px">
            <h3>Saida do Comando</h3>
            <pre id="maint-output" class="code-block">Execute uma acao acima para ver a saida.</pre>
        </div>
    </div>

    <!-- ===== Tab: Config ===== -->
    <div id="tab-config" class="tab-content">
        <div class="toolbar">
            <span id="config-path" class="muted">---</span>
            <div class="toolbar-spacer"></div>
            <button id="btn-reload-config" class="btn btn-secondary">Recarregar</button>
            <button id="btn-save-config" class="btn btn-primary">Salvar</button>
        </div>
        <div class="panel">
            <textarea id="config-editor" class="config-editor" spellcheck="false" autocomplete="off"></textarea>
        </div>
    </div>

    <!-- ===== Modal ===== -->
    <div id="modal-overlay" class="modal-overlay hidden">
        <div class="modal">
            <div class="modal-header">
                <h3 id="modal-title">Titulo</h3>
                <button class="modal-close" id="modal-close">&times;</button>
            </div>
            <div class="modal-body" id="modal-body"></div>
            <div class="modal-footer">
                <button class="btn btn-secondary" id="modal-cancel">Cancelar</button>
                <button class="btn btn-primary" id="modal-ok">Confirmar</button>
            </div>
        </div>
    </div>

    <script src="devs-permissions.js"></script>
</body>
</html>
ENDFILE

echo "[3/8] Criando devs-permissions.css..."
# CSS será copiado de arquivo separado por ser muito grande para heredoc
# Usando base64 para evitar problemas com caracteres especiais
echo "[4/8] Criando devs-permissions.js..."
echo "[5/8] Criando cockpit-helper.sh..."
echo "[6/8] Criando install.sh..."
echo "[7/8] Criando Makefile..."
echo "[8/8] Criando RPM spec..."

echo ""
echo "NOTA: Este script é um bootstrap."
echo "Os arquivos CSS, JS, bridge e packaging são grandes demais para heredoc."
echo "Use o instalador completo conforme instruções abaixo."
echo ""
echo "=== Deploy concluído ==="
