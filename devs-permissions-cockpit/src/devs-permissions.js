/*
 * DevOps Permissions Manager - Cockpit Plugin
 * Interface gráfica completa para o devs_permissions_manager.sh
 *
 * Comunicação: cockpit-helper.sh (bridge JSON)
 * Equipe: DevOps - DETRAN-CE
 * Versão: 1.0.0
 */

(function () {
    "use strict";

    /* ================================================================
     * PATHS & CONFIG
     * ================================================================ */

    var HELPER = "/usr/libexec/devs-permissions/cockpit-helper.sh";
    var CONFIG_PATH = "/etc/devs-permissions/devs_permissions.conf";
    var REFRESH_MS = 60000;
    var _refreshTimer = null;

    /* ================================================================
     * UTILITIES
     * ================================================================ */

    function esc(text) {
        var d = document.createElement("div");
        d.appendChild(document.createTextNode(text || ""));
        return d.innerHTML;
    }

    function $(id) { return document.getElementById(id); }

    function show(el) { el.classList.remove("hidden"); }
    function hide(el) { el.classList.add("hidden"); }

    function showLoading() { show($("loading-overlay")); }
    function hideLoading() { hide($("loading-overlay")); }

    function showAlert(msg, type) {
        var area = $("alert-area");
        var div = document.createElement("div");
        div.className = "alert alert-" + (type || "info");
        div.innerHTML = '<span>' + esc(msg) + '</span><button class="alert-x" onclick="this.parentElement.remove()">&times;</button>';
        area.appendChild(div);
        setTimeout(function () { if (div.parentElement) div.remove(); }, 8000);
    }

    function timeRemaining(epochStr) {
        var exp = parseInt(epochStr, 10);
        if (!exp || isNaN(exp)) return { text: "-", active: false };
        var now = Math.floor(Date.now() / 1000);
        var rem = exp - now;
        if (rem <= 0) return { text: "Expirado", active: false };
        var h = Math.floor(rem / 3600);
        var m = Math.floor((rem % 3600) / 60);
        return { text: h + "h " + m + "m", active: true };
    }

    /* ================================================================
     * COCKPIT BRIDGE COMMUNICATION
     * ================================================================ */

    /**
     * Chama o cockpit-helper.sh e retorna JSON parsed.
     * helper("get-overview") → Promise<{status, counts, groups}>
     */
    function helper(command, extraArgs) {
        var args = [HELPER, command];
        if (extraArgs) args = args.concat(extraArgs);
        return new Promise(function (resolve, reject) {
            cockpit.spawn(args, { superuser: "require", err: "message" })
                .then(function (output) {
                    try {
                        resolve(JSON.parse(output));
                    } catch (e) {
                        resolve({ status: "error", message: "Invalid JSON", raw: output });
                    }
                })
                .catch(function (ex) {
                    reject(ex.message || ex.problem || "Erro de comunicacao");
                });
        });
    }

    /**
     * Executa um comando do manager via bridge: helper run <args...>
     * manager("apply") ou manager("add-user", "--user", "joao")
     * Aceita argumentos individuais OU um array como primeiro argumento.
     */
    function manager() {
        var cmdArgs = [HELPER, "run"];
        if (arguments.length === 1 && Array.isArray(arguments[0])) {
            cmdArgs = cmdArgs.concat(arguments[0]);
        } else {
            for (var i = 0; i < arguments.length; i++) cmdArgs.push(arguments[i]);
        }
        return new Promise(function (resolve) {
            cockpit.spawn(cmdArgs, { superuser: "require", err: "message" })
                .then(function (output) {
                    try {
                        resolve(JSON.parse(output));
                    } catch (e) {
                        resolve({ status: "ok", output: output });
                    }
                })
                .catch(function (ex) {
                    resolve({ status: "error", output: ex.message || "" });
                });
        });
    }

    /**
     * Lê/escreve arquivo via cockpit.file
     */
    function readFile(path) { return cockpit.file(path, { superuser: "try" }).read(); }
    function writeFile(path, content) { return cockpit.file(path, { superuser: "require" }).replace(content); }

    /* ================================================================
     * MODAL
     * ================================================================ */

    var _modalCb = null;

    function openModal(title, bodyHtml, okLabel, cb) {
        $("modal-title").textContent = title;
        $("modal-body").innerHTML = bodyHtml;
        $("modal-ok").textContent = okLabel || "Confirmar";
        $("modal-ok").className = "btn btn-primary";
        show($("modal-overlay"));
        _modalCb = cb;
    }

    function openDangerModal(title, bodyHtml, okLabel, cb) {
        openModal(title, bodyHtml, okLabel, cb);
        $("modal-ok").className = "btn btn-danger";
    }

    function closeModal() {
        hide($("modal-overlay"));
        _modalCb = null;
    }

    $("modal-close").onclick = closeModal;
    $("modal-cancel").onclick = closeModal;
    $("modal-ok").onclick = function () {
        if (_modalCb) _modalCb();
        closeModal();
    };

    /* ================================================================
     * TAB: DASHBOARD
     * ================================================================ */

    function loadDashboard() {
        Promise.all([
            helper("get-overview"),
            helper("list-temp-access"),
            helper("list-requests")
        ]).then(function (results) {
            var ov = results[0];
            var temp = results[1];
            var reqs = results[2];

            if (ov.status !== "ok") return;

            // Stats cards
            $("stat-basic").textContent = ov.counts.basic;
            $("stat-exec").textContent = ov.counts.exec;
            $("stat-webconf").textContent = ov.counts.webconf;
            $("stat-temp").textContent = ov.counts.temp_access;
            $("stat-requests").textContent = ov.counts.pending_requests;
            $("stat-teams").textContent = ov.counts.teams;

            // Environment badge
            var env = $("header-env");
            env.textContent = (ov.environment || "").toUpperCase();
            env.className = "env-badge env-" + (ov.environment || "unknown");

            // Groups panel
            var gh = '<div class="ilist">';
            gh += '<div class="irow"><span class="ilabel">devs (Basico):</span><span>' + esc(ov.groups.basic || "Nenhum") + '</span></div>';
            gh += '<div class="irow"><span class="ilabel">devs_exec (Exec):</span><span>' + esc(ov.groups.exec || "Nenhum") + '</span></div>';
            gh += '<div class="irow"><span class="ilabel">devs_webconf (WebConf):</span><span>' + esc(ov.groups.webconf || "Nenhum") + '</span></div>';
            gh += '</div>';
            $("dash-groups").innerHTML = gh;

            // Temp access panel
            var entries = (temp && temp.entries) || [];
            if (!entries.length) {
                $("dash-temp").innerHTML = '<p class="muted">Nenhum acesso temporario ativo.</p>';
            } else {
                var th = '<div class="ilist">';
                entries.forEach(function (e) {
                    var r = timeRemaining(e.expires_epoch);
                    th += '<div class="irow"><span class="ilabel">' + esc(e.user) + '</span>';
                    th += '<span class="badge ' + (r.active ? "bg-green" : "bg-red") + '">' + r.text + '</span>';
                    if (e.reason) th += ' <span class="muted">(' + esc(e.reason) + ')</span>';
                    th += '</div>';
                });
                th += '</div>';
                $("dash-temp").innerHTML = th;
            }

            // Requests panel
            var pending = ((reqs && reqs.requests) || []).filter(function (r) { return r.status === "pending"; });
            if (!pending.length) {
                $("dash-requests").innerHTML = '<p class="muted">Nenhuma solicitacao pendente.</p>';
            } else {
                var rh = '<div class="ilist">';
                pending.forEach(function (r) {
                    rh += '<div class="irow"><span class="badge bg-yellow">' + esc(r.request_id) + '</span> ';
                    rh += '<span class="ilabel">' + esc(r.user) + '</span> - ' + esc(String(r.hours)) + 'h';
                    if (r.reason) rh += ' - ' + esc(r.reason);
                    rh += '</div>';
                });
                rh += '</div>';
                $("dash-requests").innerHTML = rh;
            }

            // Status panel - quick check
            helper("check-install").then(function (inst) {
                var sh = '<div class="ilist">';
                sh += '<div class="irow"><span class="ilabel">Manager:</span><span class="badge ' + (inst.manager_installed ? "bg-green" : "bg-red") + '">' + (inst.manager_installed ? "Instalado" : "Nao encontrado") + '</span></div>';
                sh += '<div class="irow"><span class="ilabel">Config:</span><span class="badge ' + (inst.config_exists ? "bg-green" : "bg-red") + '">' + (inst.config_exists ? "OK" : "Nao encontrado") + '</span></div>';
                if (inst.manager_version) sh += '<div class="irow"><span class="ilabel">Versao:</span><span>' + esc(inst.manager_version) + '</span></div>';
                sh += '<div class="irow"><span class="ilabel">Helper:</span><span>v' + esc(inst.helper_version) + '</span></div>';
                sh += '</div>';
                $("dash-status").innerHTML = sh;
                $("header-version").textContent = inst.manager_version || "";
            });

        }).catch(function (err) {
            showAlert("Erro ao carregar dashboard: " + err, "danger");
        });
    }

    /* ================================================================
     * TAB: USERS
     * ================================================================ */

    function loadUsers() {
        helper("list-users").then(function (data) {
            if (data.status !== "ok") {
                $("users-tbody").innerHTML = '<tr><td colspan="8" class="muted">Erro: ' + esc(data.message || "desconhecido") + '</td></tr>';
                return;
            }
            var users = data.users || [];
            if (!users.length) {
                $("users-tbody").innerHTML = '<tr><td colspan="8" class="muted">Nenhum usuario. Execute "Aplicar Configuracao".</td></tr>';
                return;
            }

            var html = "";
            users.forEach(function (u) {
                var r = u.has_temp ? timeRemaining(u.temp_expires) : { text: "-", active: false };
                html += "<tr>";
                html += '<td class="uname">' + esc(u.name) + "</td>";
                html += "<td>" + (u.basic ? '<span class="ck-yes">&#10003;</span>' : '<span class="ck-no">-</span>') + "</td>";
                html += "<td>" + (u.exec ? '<span class="ck-yes">&#10003;</span>' : '<span class="ck-no">-</span>') + "</td>";
                html += "<td>" + (u.webconf ? '<span class="ck-yes">&#10003;</span>' : '<span class="ck-no">-</span>') + "</td>";
                html += "<td>" + (u.teams ? esc(u.teams) : '<span class="muted">-</span>') + "</td>";
                if (u.has_temp) {
                    html += '<td><span class="badge ' + (r.active ? "bg-green" : "bg-red") + '">' + r.text + '</span></td>';
                } else {
                    html += '<td class="muted">-</td>';
                }
                html += "<td>" + esc(u.last_login || "-") + "</td>";
                html += '<td class="actions">';
                if (!u.exec) {
                    html += '<button class="btn btn-xs btn-success" data-act="promote" data-user="' + esc(u.name) + '">Promover</button> ';
                } else {
                    html += '<button class="btn btn-xs btn-warning" data-act="demote" data-user="' + esc(u.name) + '">Rebaixar</button> ';
                }
                if (!u.webconf) {
                    html += '<button class="btn btn-xs btn-outline" data-act="add-webconf" data-user="' + esc(u.name) + '">+WebConf</button> ';
                }
                html += '<button class="btn btn-xs btn-danger" data-act="remove-user" data-user="' + esc(u.name) + '">Remover</button>';
                html += '</td></tr>';
            });
            $("users-tbody").innerHTML = html;
            bindUserActions();
        }).catch(function (err) {
            showAlert("Erro ao listar usuarios: " + err, "danger");
        });
    }

    function bindUserActions() {
        var buttons = document.querySelectorAll("#users-tbody button[data-act]");
        buttons.forEach(function (btn) {
            btn.onclick = function () {
                var act = btn.getAttribute("data-act");
                var user = btn.getAttribute("data-user");
                switch (act) {
                    case "promote": doPromote(user); break;
                    case "demote": doDemote(user); break;
                    case "add-webconf": doAddWebconf(user); break;
                    case "remove-user": doRemoveUser(user); break;
                }
            };
        });
    }

    // Filtro de usuarios
    $("user-search").addEventListener("input", function () {
        var filter = this.value.toLowerCase();
        var rows = document.querySelectorAll("#users-tbody tr");
        rows.forEach(function (row) {
            var name = row.querySelector(".uname");
            if (!name) return;
            row.style.display = name.textContent.toLowerCase().indexOf(filter) !== -1 ? "" : "none";
        });
    });

    function doAddUser() {
        var body = '<div class="fg"><label>Nome do usuario:</label><input type="text" id="m-user" class="finput" placeholder="nome.sobrenome" /></div>';
        body += '<div class="fg"><label><input type="checkbox" id="m-exec" /> Acesso Exec (docker exec)</label></div>';
        body += '<div class="fg"><label><input type="checkbox" id="m-webconf" /> Acesso WebConf (nginx/httpd)</label></div>';
        openModal("Adicionar Usuario", body, "Adicionar", function () {
            var user = $("m-user").value.trim();
            if (!user) { showAlert("Informe o nome do usuario.", "danger"); return; }
            var args = ["add-user", "--user", user];
            if ($("m-exec").checked) args.push("--exec");
            if ($("m-webconf").checked) args.push("--webconf");
            showLoading();
            manager(args).then(function (res) {
                hideLoading();
                showAlert(res.output || "Usuario adicionado.", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    }

    function doPromote(user) {
        openModal("Promover para Exec", "<p>Promover <strong>" + esc(user) + "</strong> para nivel Exec?</p>", "Promover", function () {
            showLoading();
            manager("promote", "--user", user).then(function (res) {
                hideLoading();
                showAlert(res.output || user + " promovido.", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    }

    function doDemote(user) {
        openModal("Rebaixar Usuario", "<p>Remover acesso Exec de <strong>" + esc(user) + "</strong>?</p>", "Rebaixar", function () {
            showLoading();
            manager("demote", "--user", user).then(function (res) {
                hideLoading();
                showAlert(res.output || user + " rebaixado.", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    }

    function doAddWebconf(user) {
        openModal("Adicionar WebConf", "<p>Conceder acesso WebConf a <strong>" + esc(user) + "</strong>?</p>", "Conceder", function () {
            showLoading();
            manager("add-user", "--user", user, "--webconf").then(function (res) {
                hideLoading();
                showAlert(res.output || "WebConf concedido.", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    }

    function doRemoveUser(user) {
        openDangerModal("Remover Usuario", "<p>Remover <strong>" + esc(user) + "</strong> de todos os grupos de permissoes?</p><p class='muted'>O usuario nao sera deletado do sistema, apenas perdera as permissoes.</p>", "Remover", function () {
            showLoading();
            manager("remove-user", "--user", user).then(function (res) {
                hideLoading();
                showAlert(res.output || user + " removido.", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    }

    /* ================================================================
     * TAB: TEAMS
     * ================================================================ */

    function loadTeams() {
        helper("list-teams").then(function (data) {
            var el = $("teams-container");
            var teams = (data && data.teams) || [];
            if (!teams.length) {
                el.innerHTML = '<p class="muted">Nenhum time configurado. Edite a configuracao para adicionar.</p>';
                return;
            }
            var html = '<div class="teams-grid">';
            teams.forEach(function (t) {
                html += '<div class="team-card">';
                html += '<h4>' + esc(t.name) + '</h4>';
                html += '<div class="tsec"><span class="tlabel">Usuarios:</span>';
                if (t.users.length) {
                    html += '<ul class="tlist">';
                    t.users.forEach(function (u) { html += '<li>' + esc(u) + '</li>'; });
                    html += '</ul>';
                } else {
                    html += '<p class="muted">Nenhum</p>';
                }
                html += '</div>';
                html += '<div class="tsec"><span class="tlabel">Containers:</span>';
                if (t.containers.length) {
                    html += '<div class="tags">';
                    t.containers.forEach(function (c) { html += '<span class="tag">' + esc(c) + '</span>'; });
                    html += '</div>';
                } else {
                    html += '<p class="muted">Nenhum</p>';
                }
                html += '</div>';
                html += '<div class="tsec"><span class="tlabel">WebConf Patterns:</span>';
                if (t.webconf_patterns.length) {
                    html += '<div class="tags">';
                    t.webconf_patterns.forEach(function (p) { html += '<span class="tag tag-purple">' + esc(p) + '</span>'; });
                    html += '</div>';
                } else {
                    html += '<p class="muted">Herda dos containers</p>';
                }
                html += '</div></div>';
            });
            html += '</div>';
            el.innerHTML = html;
        }).catch(function (err) {
            showAlert("Erro ao carregar times: " + err, "danger");
        });
    }

    /* ================================================================
     * TAB: TEMP ACCESS
     * ================================================================ */

    function loadTempAccess() {
        helper("list-temp-access").then(function (data) {
            var entries = (data && data.entries) || [];
            var tbody = $("temp-tbody");
            if (!entries.length) {
                tbody.innerHTML = '<tr><td colspan="6" class="muted">Nenhum acesso temporario ativo.</td></tr>';
                return;
            }
            var html = "";
            entries.forEach(function (e) {
                var r = timeRemaining(e.expires_epoch);
                html += "<tr>";
                html += "<td>" + esc(e.user || "?") + "</td>";
                html += "<td>" + esc(e.granted_at || e.timestamp || "-") + "</td>";
                html += "<td>" + esc(e.expires_at || "-") + "</td>";
                html += '<td><span class="badge ' + (r.active ? "bg-green" : "bg-red") + '">' + r.text + '</span></td>';
                html += "<td>" + esc(e.reason || "-") + "</td>";
                html += '<td><button class="btn btn-xs btn-danger" data-act="revoke-temp" data-user="' + esc(e.user) + '">Revogar</button></td>';
                html += "</tr>";
            });
            tbody.innerHTML = html;
            document.querySelectorAll("#temp-tbody button[data-act=revoke-temp]").forEach(function (btn) {
                btn.onclick = function () { doRevokeTempAccess(btn.getAttribute("data-user")); };
            });
        }).catch(function (err) {
            showAlert("Erro ao carregar acessos temporarios: " + err, "danger");
        });
    }

    function doGrantTemp() {
        var body = '<div class="fg"><label>Usuario:</label><input type="text" id="m-tuser" class="finput" placeholder="nome.sobrenome" /></div>';
        body += '<div class="fg"><label>Horas:</label><input type="number" id="m-thours" class="finput" value="4" min="1" max="48" /></div>';
        body += '<div class="fg"><label>Motivo:</label><input type="text" id="m-treason" class="finput" placeholder="debug issue #123" /></div>';
        openModal("Conceder Acesso Temporario", body, "Conceder", function () {
            var user = $("m-tuser").value.trim();
            var hours = $("m-thours").value.trim();
            var reason = $("m-treason").value.trim();
            if (!user || !hours) { showAlert("Usuario e horas sao obrigatorios.", "danger"); return; }
            var args = ["grant-temp", "--user", user, "--hours", hours];
            if (reason) args.push("--reason", reason);
            showLoading();
            manager(args).then(function (res) {
                hideLoading();
                showAlert(res.output || "Acesso concedido.", res.status === "ok" ? "success" : "danger");
                loadTempAccess(); loadDashboard();
            });
        });
    }

    function doRevokeTempAccess(user) {
        openDangerModal("Revogar Acesso", "<p>Revogar acesso temporario de <strong>" + esc(user) + "</strong>?</p>", "Revogar", function () {
            showLoading();
            manager("revoke-temp", "--user", user).then(function (res) {
                hideLoading();
                showAlert(res.output || "Acesso revogado.", "success");
                loadTempAccess(); loadDashboard();
            });
        });
    }

    /* ================================================================
     * TAB: REQUESTS
     * ================================================================ */

    function loadRequests() {
        helper("list-requests").then(function (data) {
            var reqs = (data && data.requests) || [];
            var tbody = $("requests-tbody");
            if (!reqs.length) {
                tbody.innerHTML = '<tr><td colspan="7" class="muted">Nenhuma solicitacao.</td></tr>';
                return;
            }
            var html = "";
            reqs.forEach(function (r) {
                var sc = r.status === "pending" ? "bg-yellow" : (r.status === "approved" ? "bg-green" : "bg-red");
                html += "<tr>";
                html += "<td>" + esc(r.request_id || "?") + "</td>";
                html += "<td>" + esc(r.user || "?") + "</td>";
                html += "<td>" + esc(String(r.hours || "?")) + "h</td>";
                html += "<td>" + esc(r.reason || "-") + "</td>";
                html += "<td>" + esc(r.timestamp || "-") + "</td>";
                html += '<td><span class="badge ' + sc + '">' + esc(r.status || "?") + '</span></td>';
                html += "<td>";
                if (r.status === "pending") {
                    html += '<button class="btn btn-xs btn-success" data-act="approve" data-rid="' + esc(r.request_id) + '">Aprovar</button> ';
                    html += '<button class="btn btn-xs btn-danger" data-act="deny" data-rid="' + esc(r.request_id) + '">Negar</button>';
                } else {
                    html += '<span class="muted">-</span>';
                }
                html += "</td></tr>";
            });
            tbody.innerHTML = html;
            document.querySelectorAll("#requests-tbody button[data-act]").forEach(function (btn) {
                btn.onclick = function () {
                    var rid = btn.getAttribute("data-rid");
                    if (btn.getAttribute("data-act") === "approve") doApprove(rid);
                    else doDeny(rid);
                };
            });
        }).catch(function (err) {
            showAlert("Erro ao carregar solicitacoes: " + err, "danger");
        });
    }

    function doApprove(rid) {
        openModal("Aprovar Solicitacao", "<p>Aprovar <strong>" + esc(rid) + "</strong>?</p>", "Aprovar", function () {
            showLoading();
            manager("approve", "--request-id", rid).then(function (res) {
                hideLoading();
                showAlert(res.output || "Aprovado.", res.status === "ok" ? "success" : "danger");
                loadRequests(); loadDashboard();
            });
        });
    }

    function doDeny(rid) {
        var body = '<p>Negar solicitacao <strong>' + esc(rid) + '</strong>?</p>';
        body += '<div class="fg"><label>Motivo (opcional):</label><input type="text" id="m-dreason" class="finput" /></div>';
        openDangerModal("Negar Solicitacao", body, "Negar", function () {
            var reason = $("m-dreason").value.trim();
            var args = ["deny", "--request-id", rid];
            if (reason) args.push("--reason", reason);
            showLoading();
            manager(args).then(function (res) {
                hideLoading();
                showAlert(res.output || "Negado.", "success");
                loadRequests(); loadDashboard();
            });
        });
    }

    /* ================================================================
     * TAB: AUDIT
     * ================================================================ */

    function runAuditCmd(command, extraArgs) {
        var args = [command];
        if (extraArgs) args = args.concat(extraArgs);
        $("audit-output").textContent = "Executando...";
        showLoading();
        manager(args).then(function (res) {
            hideLoading();
            $("audit-output").textContent = res.output || res.message || "Concluido.";
        });
    }

    $("btn-audit-report").onclick = function () {
        var days = $("audit-days").value;
        var user = $("audit-user").value.trim();
        var format = $("audit-format").value;
        var extra = ["--days", days, "--format", format];
        if (user) extra.push("--user", user);
        $("audit-title").textContent = "Relatorio de Auditoria";
        runAuditCmd("audit-report", extra);
    };

    $("btn-session-report").onclick = function () {
        var days = $("audit-days").value;
        var user = $("audit-user").value.trim();
        var extra = ["--days", days];
        if (user) extra.push("--user", user);
        $("audit-title").textContent = "Relatorio de Sessoes";
        runAuditCmd("session-report", extra);
    };

    $("btn-health-check").onclick = function () {
        $("audit-title").textContent = "Health Check";
        runAuditCmd("health-check");
    };

    $("btn-inactive").onclick = function () {
        var days = $("audit-days").value;
        $("audit-title").textContent = "Usuarios Inativos";
        runAuditCmd("inactive-users", ["--days", days]);
    };

    /* ================================================================
     * TAB: MAINTENANCE
     * ================================================================ */

    function loadBackups() {
        helper("list-backups").then(function (data) {
            var backups = (data && data.backups) || [];
            var el = $("backups-list");
            if (!backups.length) {
                el.innerHTML = '<p class="muted">Nenhum backup encontrado.</p>';
                return;
            }
            var html = '<div class="ilist">';
            backups.forEach(function (b) {
                html += '<div class="irow"><span class="ilabel">' + esc(b.name) + '</span><span class="muted">' + esc(b.size) + '</span></div>';
            });
            html += '</div>';
            el.innerHTML = html;
        });
    }

    function runMaintenanceAction(action) {
        var out = $("maint-output");
        out.textContent = "Executando " + action + "...";
        showLoading();
        manager(action).then(function (res) {
            hideLoading();
            out.textContent = res.output || res.message || "Concluido.";
            if (res.status === "ok") {
                showAlert("Acao '" + action + "' executada.", "success");
            }
            loadBackups();
            loadDashboard();
        });
    }

    // Bind maintenance action buttons
    document.querySelectorAll("[data-action]").forEach(function (btn) {
        btn.onclick = function () {
            var action = btn.getAttribute("data-action");
            var isDanger = btn.classList.contains("btn-danger");
            if (isDanger) {
                openDangerModal("Confirmar Acao Destrutiva", "<p>Tem certeza que deseja executar <strong>" + esc(action) + "</strong>?</p><p class='muted'>Esta acao pode ser irreversivel.</p>", "Executar", function () {
                    runMaintenanceAction(action);
                });
            } else {
                openModal("Confirmar", "<p>Executar <strong>" + esc(action) + "</strong>?</p>", "Executar", function () {
                    runMaintenanceAction(action);
                });
            }
        };
    });

    /* ================================================================
     * TAB: CONFIG
     * ================================================================ */

    function loadConfig() {
        helper("get-config").then(function (data) {
            if (data.status === "ok") {
                $("config-editor").value = data.content || "";
                $("config-path").textContent = data.path || CONFIG_PATH;
            } else {
                $("config-editor").value = "# Erro: " + (data.message || "arquivo nao encontrado");
                $("config-path").textContent = CONFIG_PATH + " (nao encontrado)";
            }
        });
    }

    $("btn-save-config").onclick = function () {
        var content = $("config-editor").value;
        openModal("Salvar Configuracao", "<p>Salvar alteracoes? Um backup sera criado automaticamente.</p>", "Salvar", function () {
            showLoading();
            // Backup first
            manager("backup").then(function () {
                return writeFile(CONFIG_PATH, content);
            }).then(function () {
                hideLoading();
                showAlert("Configuracao salva com sucesso!", "success");
                loadDashboard();
            }).catch(function (err) {
                hideLoading();
                showAlert("Erro ao salvar: " + err, "danger");
            });
        });
    };

    $("btn-reload-config").onclick = loadConfig;

    /* ================================================================
     * NAVIGATION
     * ================================================================ */

    var tabBtns = document.querySelectorAll(".tab-btn");
    var tabPanes = document.querySelectorAll(".tab-content");

    function switchTab(id) {
        tabBtns.forEach(function (b) { b.classList.toggle("active", b.getAttribute("data-tab") === id); });
        tabPanes.forEach(function (p) { p.classList.toggle("active", p.id === "tab-" + id); });
        switch (id) {
            case "dashboard": loadDashboard(); break;
            case "users": loadUsers(); break;
            case "teams": loadTeams(); break;
            case "temp-access": loadTempAccess(); break;
            case "requests": loadRequests(); break;
            case "maintenance": loadBackups(); break;
            case "config": loadConfig(); break;
        }
    }

    tabBtns.forEach(function (btn) {
        btn.onclick = function () { switchTab(btn.getAttribute("data-tab")); };
    });

    /* ================================================================
     * TOOLBAR BUTTONS
     * ================================================================ */

    $("btn-refresh").onclick = function () {
        var active = document.querySelector(".tab-btn.active");
        if (active) switchTab(active.getAttribute("data-tab"));
    };

    $("btn-add-user").onclick = doAddUser;

    $("btn-apply").onclick = function () {
        openModal("Aplicar Configuracao", "<p>Aplicar todas as configuracoes? Cria/atualiza usuarios, grupos, sudoers, wrapper Docker, cron jobs e ACLs.</p>", "Aplicar", function () {
            showLoading();
            manager("apply").then(function (res) {
                hideLoading();
                showAlert(res.output ? "Configuracao aplicada!" : "Erro", res.status === "ok" ? "success" : "danger");
                loadUsers(); loadDashboard();
            });
        });
    };

    $("btn-sync").onclick = function () {
        showLoading();
        manager("sync").then(function (res) {
            hideLoading();
            showAlert(res.output || "Sincronizado.", res.status === "ok" ? "success" : "danger");
            loadUsers(); loadDashboard();
        });
    };

    $("btn-grant-temp").onclick = doGrantTemp;

    $("btn-cleanup-expired").onclick = function () {
        showLoading();
        manager("cleanup").then(function (res) {
            hideLoading();
            showAlert(res.output || "Limpeza concluida.", "success");
            loadTempAccess(); loadDashboard();
        });
    };

    /* ================================================================
     * INIT
     * ================================================================ */

    helper("check-install").then(function (data) {
        if (!data.manager_installed) {
            show($("install-warning"));
        }
        loadDashboard();
    }).catch(function () {
        show($("install-warning"));
        showAlert("Erro ao conectar com o helper. Verifique a instalacao.", "danger");
    });

    _refreshTimer = setInterval(function () {
        var active = document.querySelector(".tab-btn.active");
        if (active && active.getAttribute("data-tab") === "dashboard") {
            loadDashboard();
        }
    }, REFRESH_MS);

})();
