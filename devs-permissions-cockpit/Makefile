NAME = devs-permissions-cockpit
VERSION = 1.0.0
COCKPIT_DIR = /usr/share/cockpit/$(NAME)
LIBEXEC_DIR = /usr/libexec/devs-permissions
CONFIG_DIR = /etc/devs-permissions
DATA_DIR = /var/lib/devs_permissions
LOG_DIR = /var/log/devs_audit
BACKUP_DIR = /var/backups/devs_permissions

TARBALL = $(NAME)-$(VERSION).tar.gz
SPECFILE = packaging/$(NAME).spec

SRC_FILES = src/manifest.json src/index.html src/devs-permissions.js src/devs-permissions.css
BRIDGE_FILES = bridge/cockpit-helper.sh

.PHONY: all install uninstall rpm srpm tarball clean dirs

all:
	@echo "Uso:"
	@echo "  make install       - Instala o plugin (requer root)"
	@echo "  make uninstall     - Remove o plugin (requer root)"
	@echo "  make rpm           - Gera pacote RPM"
	@echo "  make tarball       - Gera tarball para rpmbuild"
	@echo "  make clean         - Limpa artefatos de build"

# ==== INSTALAÇÃO DIRETA ====

dirs:
	mkdir -p $(DESTDIR)$(COCKPIT_DIR)
	mkdir -p $(DESTDIR)$(LIBEXEC_DIR)
	mkdir -p $(DESTDIR)$(CONFIG_DIR)
	mkdir -p $(DESTDIR)$(DATA_DIR)/temp_access
	mkdir -p $(DESTDIR)$(DATA_DIR)/requests
	mkdir -p $(DESTDIR)$(LOG_DIR)/sessions
	mkdir -p $(DESTDIR)$(BACKUP_DIR)

install: dirs
	install -m 644 src/manifest.json $(DESTDIR)$(COCKPIT_DIR)/
	install -m 644 src/index.html $(DESTDIR)$(COCKPIT_DIR)/
	install -m 644 src/devs-permissions.js $(DESTDIR)$(COCKPIT_DIR)/
	install -m 644 src/devs-permissions.css $(DESTDIR)$(COCKPIT_DIR)/
	install -m 755 bridge/cockpit-helper.sh $(DESTDIR)$(LIBEXEC_DIR)/
	@echo ""
	@echo "Plugin instalado em $(COCKPIT_DIR)"
	@echo "Helper instalado em $(LIBEXEC_DIR)"
	@echo ""
	@echo "Reinicie o Cockpit: systemctl restart cockpit.socket"

uninstall:
	rm -rf $(DESTDIR)$(COCKPIT_DIR)
	rm -f $(DESTDIR)$(LIBEXEC_DIR)/cockpit-helper.sh
	@echo "Plugin removido."
	@echo "Reinicie o Cockpit: systemctl restart cockpit.socket"

# ==== BUILD RPM ====

tarball:
	mkdir -p build
	mkdir -p build/$(NAME)-$(VERSION)
	cp -r src bridge packaging Makefile build/$(NAME)-$(VERSION)/
	tar -czf build/$(TARBALL) -C build $(NAME)-$(VERSION)
	@echo "Tarball criado: build/$(TARBALL)"

rpm: tarball
	mkdir -p build/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
	cp build/$(TARBALL) build/SOURCES/
	cp $(SPECFILE) build/SPECS/
	rpmbuild --define "_topdir $(CURDIR)/build" -bb build/SPECS/$(NAME).spec
	@echo ""
	@echo "RPM gerado em: build/RPMS/noarch/"
	@find build/RPMS -name "*.rpm" -exec echo "  {}" \;

srpm: tarball
	mkdir -p build/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
	cp build/$(TARBALL) build/SOURCES/
	cp $(SPECFILE) build/SPECS/
	rpmbuild --define "_topdir $(CURDIR)/build" -bs build/SPECS/$(NAME).spec
	@echo "SRPM gerado em: build/SRPMS/"

clean:
	rm -rf build
