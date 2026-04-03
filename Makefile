# Kin AI Raspberry Pi client wrapper — common operations
# Run from this directory (the wrapper root on the Pi).

SUDO := sudo
CLIENT_DIR := raspberry-pi-client

.PHONY: help install uninstall uninstall-y reinstall \
	start stop stop-dev restart status \
	start-otel stop-otel restart-otel status-otel \
	boot-status enable-boot disable-boot show-branch \
	logs logs-follow logs-all logs-otel logs-otel-follow \
	diagnostics daemon-reload pull-client

help:
	@echo "Kin AI forge (wrapper) — common commands"
	@echo ""
	@echo "Stop for local dev (still starts on reboot if enabled):"
	@echo "  make stop-dev         Stop launcher, then show enabled/active"
	@echo "  make stop             Stop launcher only (does not disable systemd)"
	@echo "  make boot-status      Show enabled + active for both units"
	@echo "  make start            Start launcher when done testing"
	@echo "  make show-branch      Show GIT_BRANCH from .env (else default main)"
	@echo "  (Push branch; set GIT_BRANCH=... in .env so reboot pulls that branch.)"
	@echo ""
	@echo "Boot auto-start:"
	@echo "  make enable-boot      Enable xavier + otelcol on reboot"
	@echo "  make disable-boot     Disable both (no auto-start after reboot)"
	@echo ""
	@echo "  make install          Initial setup (./install.sh)"
	@echo "  make reinstall        Stop, uninstall, reinstall"
	@echo "  make uninstall        Remove services and client (prompts)"
	@echo "  make uninstall-y      Same as uninstall, no prompts (-y)"
	@echo ""
	@echo "  make start            sudo systemctl start xavier"
	@echo "  make stop             sudo systemctl stop xavier"
	@echo "  make restart          sudo systemctl restart xavier"
	@echo "  make status           systemctl status xavier"
	@echo ""
	@echo "  make start-otel       sudo systemctl start otelcol"
	@echo "  make stop-otel        sudo systemctl stop otelcol"
	@echo "  make restart-otel     sudo systemctl restart otelcol"
	@echo "  make status-otel      systemctl status otelcol"
	@echo ""
	@echo "  make logs             Last 80 lines, xavier"
	@echo "  make logs-follow      Follow xavier journal"
	@echo "  make logs-all         Follow xavier + otelcol"
	@echo "  make logs-otel        Last 80 lines, otelcol"
	@echo "  make logs-otel-follow Follow otelcol journal"
	@echo ""
	@echo "  make diagnostics      Run device diagnostics (stops/restarts launcher)"
	@echo "  make daemon-reload    After editing files in services/"
	@echo ""
	@echo "  make pull-client      git pull in $(CLIENT_DIR) (if repo exists)"

install:
	@chmod +x install.sh
	./install.sh

uninstall:
	@chmod +x uninstall.sh
	./uninstall.sh

uninstall-y:
	@chmod +x uninstall.sh
	./uninstall.sh -y

reinstall:
	@chmod +x reinstall.sh
	./reinstall.sh

start:
	$(SUDO) systemctl start xavier

stop:
	$(SUDO) systemctl stop xavier

stop-dev: stop
	@echo ""
	@echo "Launcher stopped. systemd enable state is unchanged (reboot will still start it if enabled)."
	@$(MAKE) --no-print-directory boot-status

boot-status:
	@echo 'xavier:'
	@systemctl show xavier -p UnitFileState -p ActiveState --no-pager 2>/dev/null \
		|| echo '  (unit not found — run make install)'
	@echo 'otelcol:'
	@systemctl show otelcol -p UnitFileState -p ActiveState --no-pager 2>/dev/null \
		|| echo '  (unit not found — run make install)'

enable-boot:
	$(SUDO) systemctl enable xavier otelcol
	@echo "Enabled for boot (does not start units now unless already running)."

disable-boot:
	$(SUDO) systemctl disable xavier otelcol
	@echo "Disabled for boot. Use: make enable-boot"

show-branch:
	@if [ -f .env ] && grep -q '^GIT_BRANCH=' .env; then \
		grep '^GIT_BRANCH=' .env | head -1; \
	else \
		echo 'GIT_BRANCH not in .env — launch.sh defaults to main'; \
	fi

restart:
	$(SUDO) systemctl restart xavier

status:
	$(SUDO) systemctl status xavier

start-otel:
	$(SUDO) systemctl start otelcol

stop-otel:
	$(SUDO) systemctl stop otelcol

restart-otel:
	$(SUDO) systemctl restart otelcol

status-otel:
	$(SUDO) systemctl status otelcol

logs:
	$(SUDO) journalctl -u xavier -n 80 --no-pager

logs-follow:
	$(SUDO) journalctl -u xavier -f

logs-all:
	$(SUDO) journalctl -u xavier -u otelcol -f

logs-otel:
	$(SUDO) journalctl -u otelcol -n 80 --no-pager

logs-otel-follow:
	$(SUDO) journalctl -u otelcol -f

diagnostics:
	bash diagnostics/run-device-diagnostics.sh

daemon-reload:
	$(SUDO) systemctl daemon-reload

pull-client:
	@test -d $(CLIENT_DIR)/.git || (echo "No git repo at $(CLIENT_DIR)"; exit 1)
	cd $(CLIENT_DIR) && git pull
