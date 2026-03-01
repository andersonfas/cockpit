Name:           devs-permissions-cockpit
Version:        1.0.0
Release:        1%{?dist}
Summary:        Cockpit plugin for DevOps Permissions Manager

License:        MIT
URL:            https://github.com/andersonfas/devs-permissions-cockpit
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       cockpit-system >= 264
Requires:       cockpit-bridge >= 264
Requires:       bash >= 4.0
Requires:       coreutils

%description
Plugin web para o Cockpit que fornece interface grafica completa para o
DevOps Permissions Manager (devs_permissions_manager.sh).

Funcionalidades:
- Dashboard com visao geral do sistema
- Gestao de usuarios (basico, exec, webconf)
- Visualizacao de times e restricoes por container
- Concessao e revogacao de acesso temporario
- Aprovacao de solicitacoes de acesso
- Relatorios de auditoria e health check
- Manutencao (backup, sync, cleanup)
- Editor de configuracao

%prep
%setup -q

%install
# Plugin Cockpit
mkdir -p %{buildroot}%{_datadir}/cockpit/%{name}
install -m 644 src/manifest.json %{buildroot}%{_datadir}/cockpit/%{name}/
install -m 644 src/index.html %{buildroot}%{_datadir}/cockpit/%{name}/
install -m 644 src/devs-permissions.js %{buildroot}%{_datadir}/cockpit/%{name}/
install -m 644 src/devs-permissions.css %{buildroot}%{_datadir}/cockpit/%{name}/

# Bridge helper
mkdir -p %{buildroot}%{_libexecdir}/devs-permissions
install -m 755 bridge/cockpit-helper.sh %{buildroot}%{_libexecdir}/devs-permissions/

# Diretorio de config (o .conf nao e incluido - vem do pacote principal ou manual)
mkdir -p %{buildroot}%{_sysconfdir}/devs-permissions

# Diretorio de dados
mkdir -p %{buildroot}%{_localstatedir}/lib/devs_permissions/temp_access
mkdir -p %{buildroot}%{_localstatedir}/lib/devs_permissions/requests
mkdir -p %{buildroot}%{_localstatedir}/log/devs_audit/sessions
mkdir -p %{buildroot}%{_localstatedir}/backups/devs_permissions

%files
%{_datadir}/cockpit/%{name}/
%{_libexecdir}/devs-permissions/cockpit-helper.sh
%dir %{_sysconfdir}/devs-permissions
%dir %{_localstatedir}/lib/devs_permissions
%dir %{_localstatedir}/lib/devs_permissions/temp_access
%dir %{_localstatedir}/lib/devs_permissions/requests
%dir %{_localstatedir}/log/devs_audit
%dir %{_localstatedir}/log/devs_audit/sessions
%dir %{_localstatedir}/backups/devs_permissions

%post
# Reinicia cockpit para detectar novo plugin
systemctl try-restart cockpit.socket 2>/dev/null || true
echo ""
echo "======================================================"
echo " devs-permissions-cockpit instalado com sucesso!"
echo "======================================================"
echo ""
echo " Acesse: https://$(hostname -f 2>/dev/null || hostname):9090"
echo " Menu: DevOps Permissions"
echo ""
echo " IMPORTANTE: Copie seus scripts para os caminhos FHS:"
echo "   cp devs_permissions_manager.sh /usr/libexec/devs-permissions/"
echo "   cp devs_permissions.conf /etc/devs-permissions/"
echo "   chmod +x /usr/libexec/devs-permissions/devs_permissions_manager.sh"
echo ""

%postun
systemctl try-restart cockpit.socket 2>/dev/null || true

%changelog
* Sat Mar 01 2026 DevOps DETRAN-CE <devops@detran.ce.gov.br> - 1.0.0-1
- Release inicial do plugin Cockpit
- Dashboard completo com stats
- Gestao de usuarios (add, remove, promote, demote)
- Times e restricoes por container
- Acesso temporario e solicitacoes
- Auditoria e health check
- Manutencao e backups
- Editor de configuracao
