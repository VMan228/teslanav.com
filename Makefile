# ===============================================================================
# TeslaNav - Production Makefile  (Ubuntu 24.x LTS)
# ===============================================================================
#
#  First deploy (run as root):
#    make setup  DOMAIN=nav.example.com
#    make env-init && nano .env
#    make ssl    DOMAIN=nav.example.com  ACME_EMAIL=you@example.com
#    make cookies DOMAIN=nav.example.com
#    make deploy
#
#  Rolling update (subsequent deploys):
#    make update
#
#  Daily ops:
#    make status | make logs | make logs-sidecar
#
# ===============================================================================

# -- Configuration (override on the command line) ------------------------------
DOMAIN      ?=
ACME_EMAIL  ?= $(if $(DOMAIN),webmaster@$(DOMAIN),)
SIDECAR_DIR := /opt/waze-sidecar
NGINX_CONF  := /etc/nginx/sites-available/teslanav
COMPOSE     := docker compose

# Detect Ubuntu codename at parse time (used by Docker apt repo line)
UBUNTU_CODENAME := $(shell . /etc/os-release 2>/dev/null && echo $${VERSION_CODENAME} || echo noble)

SHELL := /bin/bash

# -- ANSI helpers (silenced on non-interactive terminals) ----------------------
_tty := $(shell [ -t 1 ] && echo yes)
ifeq ($(_tty),yes)
  BOLD   := $(shell printf '\033[1m')
  RESET  := $(shell printf '\033[0m')
  GREEN  := $(shell printf '\033[32m')
  YELLOW := $(shell printf '\033[33m')
  RED    := $(shell printf '\033[31m')
  CYAN   := $(shell printf '\033[36m')
else
  BOLD   :=
  RESET  :=
  GREEN  :=
  YELLOW :=
  RED    :=
  CYAN   :=
endif

.DEFAULT_GOAL := help

.PHONY: help \
        setup setup-docker setup-sidecar setup-nginx \
        ssl \
        setup-tunnel restart-tunnel logs-tunnel \
        setup-warp \
        setup-socks5 \
        env-init env-check \
        deploy build up down \
        update pull update-sidecar \
        restart restart-sidecar \
        status logs logs-sidecar logs-tunnel shell \
        cookies rollback \
        _check-root _check-domain _check-env

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
help:
	@printf '\n$(BOLD)TeslaNav - Production Makefile$(RESET)\n\n'
	@printf '$(CYAN)First-time setup$(RESET) (run as root):\n'
	@printf '  make setup   DOMAIN=nav.example.com\n'
	@printf '  make env-init && nano .env\n'
	@printf '  make ssl          DOMAIN=nav.example.com  ACME_EMAIL=you@example.com\n'
	@printf '  make setup-tunnel DOMAIN=nav.example.com  (alternative to ssl + nginx)\n'
	@printf '  make setup-warp                           (improve Waze IP trust score)\n'
	@printf '  make cookies DOMAIN=nav.example.com\n'
	@printf '  make deploy\n\n'
	@printf '$(CYAN)Deployment$(RESET):\n'
	@printf '  make deploy          Build image and start all services\n'
	@printf '  make update          Pull latest code, rebuild, restart (rolling)\n'
	@printf '  make down            Stop and remove containers\n\n'
	@printf '$(CYAN)Environment$(RESET):\n'
	@printf '  make env-init        Create .env from .env.example\n'
	@printf '  make env-check       Verify required vars are present\n\n'
	@printf '$(CYAN)Operations$(RESET):\n'
	@printf '  make status          Show status of all services\n'
	@printf '  make logs            Follow teslanav container logs\n'
	@printf '  make logs-sidecar    Follow waze-sidecar systemd journal\n'
	@printf '  make logs-tunnel     Follow cloudflared systemd journal\n'
	@printf '  make restart         Restart teslanav container\n'
	@printf '  make restart-sidecar Restart waze-sidecar systemd service\n'
	@printf '  make restart-tunnel  Restart cloudflared systemd service\n'
	@printf '  make shell           Open shell in running teslanav container\n'
	@printf '  make rollback        List recent commits for manual rollback\n\n'
	@printf '$(CYAN)Cookie bootstrap$(RESET):\n'
	@printf '  make cookies DOMAIN=nav.example.com\n\n'

# ----------------------------------------------------------------------------
# Guards
# ----------------------------------------------------------------------------
_check-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
		printf '$(RED)Error: this target requires root - prefix with sudo$(RESET)\n'; \
		exit 1; \
	fi

_check-domain:
	@if [ -z '$(DOMAIN)' ]; then \
		printf '$(RED)Error: DOMAIN is required  ->  make ... DOMAIN=nav.example.com$(RESET)\n'; \
		exit 1; \
	fi

_check-env:
	@if [ ! -f .env ]; then \
		printf '$(RED)Error: .env not found - run: make env-init$(RESET)\n'; \
		exit 1; \
	fi

# ----------------------------------------------------------------------------
# First-time setup   (requires root)
# ----------------------------------------------------------------------------

## Run all first-time setup steps in order
setup: _check-root _check-domain setup-docker setup-sidecar setup-nginx
	@printf '\n$(GREEN)$(BOLD)Setup complete.$(RESET)\n\n'
	@printf 'Next steps:\n'
	@printf '  1. make env-init && nano .env\n'
	@printf '  2. make ssl     DOMAIN=$(DOMAIN) ACME_EMAIL=you@example.com\n'
	@printf '  3. make cookies DOMAIN=$(DOMAIN)\n'
	@printf '  4. make deploy\n\n'

## Install Docker CE + Compose plugin from the official Docker apt repository
setup-docker: _check-root
	@printf '$(BOLD)Installing Docker CE...$(RESET)\n'
	apt-get update -qq
	apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
		| gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	chmod a+r /etc/apt/keyrings/docker.gpg
	echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
		https://download.docker.com/linux/ubuntu $(UBUNTU_CODENAME) stable" \
		> /etc/apt/sources.list.d/docker.list
	apt-get update -qq
	apt-get install -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker
	@printf '$(GREEN)Docker installed: $$(docker --version)$(RESET)\n'

## Install the Waze Playwright sidecar as a systemd service with Xvfb
setup-sidecar: _check-root
	@printf '$(BOLD)Installing Waze sidecar...$(RESET)\n'
	bash services/waze-sidecar/deploy/setup.sh
	@printf '$(GREEN)Sidecar installed.$(RESET)\n'
	@printf '$(YELLOW)Action required: fill in $(SIDECAR_DIR)/.env (WAZE_EMAIL at minimum)$(RESET)\n'

## Install nginx and write the reverse-proxy config for DOMAIN
setup-nginx: _check-root _check-domain
	@printf '$(BOLD)Installing nginx and configuring reverse proxy for $(DOMAIN)...$(RESET)\n'
	apt-get install -y --no-install-recommends nginx
	systemctl enable --now nginx
	sed 's/TESLANAV_DOMAIN/$(DOMAIN)/g' deploy/nginx.conf.template > $(NGINX_CONF)
	ln -sf $(NGINX_CONF) /etc/nginx/sites-enabled/teslanav
	rm -f /etc/nginx/sites-enabled/default
	nginx -t
	systemctl reload nginx
	@printf '$(GREEN)nginx configured. Port 80 -> localhost:3000$(RESET)\n'

# ----------------------------------------------------------------------------
# SSL   (requires root + DNS pointing at this server)
# ----------------------------------------------------------------------------

## Obtain a Let's Encrypt certificate via Cloudflare DNS and configure HTTPS in nginx
ssl: _check-root _check-domain _check-env
	@printf "$(BOLD)Obtaining Let's Encrypt certificate for $(DOMAIN) via Cloudflare DNS...$(RESET)\n"
	apt-get install -y --no-install-recommends certbot python3-certbot-nginx python3-certbot-dns-cloudflare
	@CF_TOKEN=$$(grep -E '^CLOUDFLARE_API_TOKEN=' .env | cut -d= -f2- | tr -d '"'); \
	if [ -z "$$CF_TOKEN" ]; then \
		printf '$(RED)Error: CLOUDFLARE_API_TOKEN not set in .env$(RESET)\n'; \
		exit 1; \
	fi; \
	install -m 600 /dev/null /etc/letsencrypt/cloudflare.ini; \
	printf 'dns_cloudflare_api_token = %s\n' "$$CF_TOKEN" > /etc/letsencrypt/cloudflare.ini; \
	certbot --authenticator dns-cloudflare \
		--installer nginx \
		--dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
		--dns-cloudflare-propagation-seconds 60 \
		-d $(DOMAIN) \
		--non-interactive \
		--agree-tos \
		--email $(ACME_EMAIL) \
		--redirect
	@printf '$(GREEN)HTTPS enabled. Auto-renewal is handled by certbot.$(RESET)\n'
	@printf 'Verify: certbot renew --dry-run\n'

# ----------------------------------------------------------------------------
# Cloudflare Tunnel   (alternative to ssl + nginx for public ingress)
# ----------------------------------------------------------------------------

## Install cloudflared, create tunnel named teslanav, wire DNS and ingress
## Requires in .env: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID
## Token needs: Account/Cloudflare Tunnel/Edit + Zone/DNS/Edit
setup-tunnel: _check-root _check-domain _check-env
	@printf '$(BOLD)Installing cloudflared...$(RESET)\n'
	curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
		| gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
	echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
		> /etc/apt/sources.list.d/cloudflared.list
	apt-get update -qq
	apt-get install -y --no-install-recommends cloudflared jq
	@printf '$(BOLD)Provisioning tunnel via Cloudflare API...$(RESET)\n'
	@set -e; \
	CF_TOKEN=$$(grep -E '^CLOUDFLARE_API_TOKEN=' .env | cut -d= -f2- | tr -d '"'); \
	ACCOUNT_ID=$$(grep -E '^CLOUDFLARE_ACCOUNT_ID=' .env | cut -d= -f2- | tr -d '"'); \
	ZONE_ID=$$(grep -E '^CLOUDFLARE_ZONE_ID=' .env | cut -d= -f2- | tr -d '"'); \
	if [ -z "$$CF_TOKEN" ] || [ -z "$$ACCOUNT_ID" ] || [ -z "$$ZONE_ID" ]; then \
		printf '$(RED)Error: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, and CLOUDFLARE_ZONE_ID must all be set in .env$(RESET)\n'; \
		exit 1; \
	fi; \
	TUNNEL_NAME=teslanav; \
	TUNNEL_ID=$$(curl -sf \
		"https://api.cloudflare.com/client/v4/accounts/$$ACCOUNT_ID/cfd_tunnel?name=$$TUNNEL_NAME&is_deleted=false" \
		-H "Authorization: Bearer $$CF_TOKEN" | jq -r '.result[0].id // empty'); \
	if [ -n "$$TUNNEL_ID" ]; then \
		printf 'Reusing existing tunnel: %s\n' "$$TUNNEL_ID"; \
	else \
		TUNNEL_ID=$$(curl -sf -X POST \
			"https://api.cloudflare.com/client/v4/accounts/$$ACCOUNT_ID/cfd_tunnel" \
			-H "Authorization: Bearer $$CF_TOKEN" \
			-H "Content-Type: application/json" \
			-d "{\"name\":\"$$TUNNEL_NAME\",\"config_src\":\"cloudflare\"}" \
			| jq -r '.result.id'); \
		printf 'Created tunnel: %s\n' "$$TUNNEL_ID"; \
	fi; \
	curl -sf -X PUT \
		"https://api.cloudflare.com/client/v4/accounts/$$ACCOUNT_ID/cfd_tunnel/$$TUNNEL_ID/configurations" \
		-H "Authorization: Bearer $$CF_TOKEN" \
		-H "Content-Type: application/json" \
		-d "{\"config\":{\"ingress\":[{\"hostname\":\"$(DOMAIN)\",\"service\":\"http://localhost:3000\"},{\"service\":\"http_status:404\"}]}}" \
		>/dev/null; \
	EXISTING_REC=$$(curl -sf \
		"https://api.cloudflare.com/client/v4/zones/$$ZONE_ID/dns_records?name=$(DOMAIN)&type=CNAME" \
		-H "Authorization: Bearer $$CF_TOKEN" | jq -r '.result[0].id // empty'); \
	if [ -n "$$EXISTING_REC" ]; then \
		curl -sf -X DELETE \
			"https://api.cloudflare.com/client/v4/zones/$$ZONE_ID/dns_records/$$EXISTING_REC" \
			-H "Authorization: Bearer $$CF_TOKEN" >/dev/null; \
	fi; \
	curl -sf -X POST \
		"https://api.cloudflare.com/client/v4/zones/$$ZONE_ID/dns_records" \
		-H "Authorization: Bearer $$CF_TOKEN" \
		-H "Content-Type: application/json" \
		-d "{\"type\":\"CNAME\",\"name\":\"$(DOMAIN)\",\"content\":\"$$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}" \
		>/dev/null; \
	TUNNEL_TOKEN=$$(curl -sf \
		"https://api.cloudflare.com/client/v4/accounts/$$ACCOUNT_ID/cfd_tunnel/$$TUNNEL_ID/token" \
		-H "Authorization: Bearer $$CF_TOKEN" | jq -r '.result'); \
	cloudflared service uninstall 2>/dev/null || true; \
	cloudflared service install "$$TUNNEL_TOKEN"
	systemctl enable --now cloudflared
	@printf '\n$(GREEN)$(BOLD)Cloudflare Tunnel active.$(RESET)\n'
	@printf '$(DOMAIN) -> tunnel -> localhost:3000\n'
	@printf 'Logs:   make logs-tunnel\n\n'

## Restart the cloudflared systemd service (requires root)
restart-tunnel: _check-root
	systemctl restart cloudflared
	@printf '$(GREEN)cloudflared restarted.$(RESET)\n'

## Follow cloudflared systemd journal (Ctrl-C to exit)
logs-tunnel:
	journalctl -u cloudflared -f

# ----------------------------------------------------------------------------
# Cloudflare WARP   (improves outbound IP trust score for Waze georss)
# ----------------------------------------------------------------------------

## Install SSH SOCKS5 tunnel service routing Playwright through a residential Windows machine
## Requires WINDOWS_USER=<username> on the command line
setup-socks5: _check-root
	@if [ -z '$(WINDOWS_USER)' ]; then \
		printf '$(RED)Error: WINDOWS_USER is required  ->  make setup-socks5 WINDOWS_USER=yourname$(RESET)\n'; \
		exit 1; \
	fi
	@printf '$(BOLD)Installing waze-socks5 systemd service...$(RESET)\n'
	sed 's/REPLACE_WITH_WINDOWS_USERNAME/$(WINDOWS_USER)/g' \
		services/waze-sidecar/deploy/waze-socks5.service \
		> /etc/systemd/system/waze-socks5.service
	systemctl daemon-reload
	systemctl enable --now waze-socks5
	@printf '$(GREEN)waze-socks5 service installed.$(RESET)\n'
	@printf 'Check tunnel: systemctl status waze-socks5\n'
	@printf 'Then set in /opt/waze-sidecar/.env:\n'
	@printf '  BROWSER_PROXY_URL=socks5://127.0.0.1:1080\n'
	@printf 'And restart: make restart-sidecar\n\n'

## Install Cloudflare WARP and route all outbound server traffic via Cloudflare
setup-warp: _check-root
	@printf '$(BOLD)Setting up Cloudflare WARP...$(RESET)\n'
	bash services/waze-sidecar/deploy/setup-warp.sh
	@printf '\n$(GREEN)WARP active. Restart waze-sidecar to use the new route:$(RESET)\n'
	@printf '  make restart-sidecar\n'
	@printf 'Disconnect: warp-cli disconnect\n'
	@printf 'Reconnect:  warp-cli connect\n\n'

# ----------------------------------------------------------------------------
# Environment
# ----------------------------------------------------------------------------

## Create .env from .env.example (skips if .env already exists)
env-init:
	@if [ -f .env ]; then \
		printf '$(YELLOW).env already exists - skipping. Delete it first to reinitialize.$(RESET)\n'; \
	else \
		cp .env.example .env; \
		printf '$(GREEN).env created from .env.example$(RESET)\n'; \
		printf 'Edit it now: nano .env\n'; \
	fi

## Verify that all required env vars have non-placeholder values
env-check: _check-env
	@printf '$(BOLD)Checking required env vars in .env...$(RESET)\n'
	@missing=0; \
	for var in NEXT_PUBLIC_MAPBOX_TOKEN UPSTASH_REDIS_REST_URL \
	           UPSTASH_REDIS_REST_TOKEN ADMIN_API_KEY; do \
		val=$$(grep -E "^$${var}=" .env | cut -d= -f2- | tr -d '"'); \
		if [ -z "$$val" ] || printf '%s' "$$val" | \
		   grep -qE 'PLACEHOLDER|your-|REPLACE|^\.\.\.|^pk\.\.\.'; then \
			printf '  $(RED)FAIL %s is not set$(RESET)\n' "$$var"; \
			missing=$$((missing+1)); \
		else \
			printf '  $(GREEN)OK %s$(RESET)\n' "$$var"; \
		fi; \
	done; \
	if [ $$missing -gt 0 ]; then \
		printf '$(RED)%d required var(s) missing - edit .env and retry$(RESET)\n' "$$missing"; \
		exit 1; \
	fi
	@printf '$(GREEN)All required vars are set.$(RESET)\n'

# ----------------------------------------------------------------------------
# Deployment
# ----------------------------------------------------------------------------

## Build image and start all services (env-check runs first)
deploy: env-check build up
	@printf '\n$(GREEN)$(BOLD)Deployed.$(RESET)\n'
	@if [ -n '$(DOMAIN)' ]; then \
		printf 'Running at https://$(DOMAIN)\n\n'; \
	else \
		printf 'Running at http://localhost:3000\n\n'; \
	fi

## Build the teslanav Docker image
build: _check-env
	@printf '$(BOLD)Building Docker image...$(RESET)\n'
	$(COMPOSE) build
	@printf '$(GREEN)Build complete.$(RESET)\n'

## Start containers (does not rebuild - use deploy or build+up for that)
up: _check-env
	@printf '$(BOLD)Starting containers...$(RESET)\n'
	$(COMPOSE) up -d
	@printf '$(GREEN)Containers started.$(RESET)\n'

## Stop and remove all containers (data is preserved in volumes/bind mounts)
down:
	$(COMPOSE) down

# ----------------------------------------------------------------------------
# Rolling update
# ----------------------------------------------------------------------------

## Pull latest code, rebuild image, restart container + sidecar  (requires root for sidecar sync)
update: pull build up update-sidecar
	@printf '\n$(GREEN)$(BOLD)Update complete.$(RESET)\n\n'

## Fast-forward pull (fails loudly on merge conflicts)
pull:
	@printf '$(BOLD)Pulling latest code...$(RESET)\n'
	git pull --ff-only

## Sync sidecar source to /opt/waze-sidecar, reinstall deps, restart service
update-sidecar: _check-root
	@printf '$(BOLD)Syncing waze-sidecar source...$(RESET)\n'
	rsync -a --delete \
		--exclude='.env' \
		--exclude='data/' \
		--exclude='.venv/' \
		--exclude='.playwright-browsers/' \
		--exclude='__pycache__/' \
		services/waze-sidecar/ $(SIDECAR_DIR)/
	chown -R waze-sidecar:waze-sidecar $(SIDECAR_DIR)
	$(SIDECAR_DIR)/.venv/bin/pip install -q -r $(SIDECAR_DIR)/requirements.txt
	systemctl restart waze-sidecar
	@printf '$(GREEN)waze-sidecar synced and restarted.$(RESET)\n'

# ----------------------------------------------------------------------------
# Service control
# ----------------------------------------------------------------------------

## Restart the teslanav Docker container
restart:
	$(COMPOSE) restart teslanav
	@printf '$(GREEN)teslanav restarted.$(RESET)\n'

## Restart the waze-sidecar systemd service (requires root)
restart-sidecar: _check-root
	systemctl restart waze-sidecar
	@printf '$(GREEN)waze-sidecar restarted.$(RESET)\n'

# ----------------------------------------------------------------------------
# Monitoring
# ----------------------------------------------------------------------------

## Show status of all services: Docker, waze-sidecar, nginx, cloudflared
status:
	@printf '$(BOLD)=== Docker containers ===$(RESET)\n'
	$(COMPOSE) ps
	@printf '\n$(BOLD)=== Waze sidecar ===$(RESET)\n'
	systemctl status waze-sidecar --no-pager -l || true
	@printf '\n$(BOLD)=== nginx ===$(RESET)\n'
	systemctl status nginx --no-pager -l || true
	@printf '\n$(BOLD)=== Cloudflare Tunnel ===$(RESET)\n'
	systemctl status cloudflared --no-pager -l || true
	@printf '\n$(BOLD)=== Cloudflare WARP ===$(RESET)\n'
	warp-cli status 2>/dev/null || printf '  (not installed)\n'

## Follow teslanav container logs (Ctrl-C to exit)
logs:
	$(COMPOSE) logs -f teslanav

## Follow waze-sidecar systemd journal (Ctrl-C to exit)
logs-sidecar:
	journalctl -u waze-sidecar -f

## Open an interactive shell inside the running teslanav container
shell:
	$(COMPOSE) exec teslanav sh

# ----------------------------------------------------------------------------
# Waze cookie bootstrap
# ----------------------------------------------------------------------------

## Print step-by-step instructions for seeding fresh Waze session cookies
cookies: _check-domain
	@printf '\n$(BOLD)Waze Cookie Bootstrap$(RESET)\n'
	@printf '===================================================\n\n'
	@printf 'The waze-sidecar needs a valid Waze session cookie file (expires ~30 days).\n'
	@printf 'Run these commands on your $(BOLD)local machine$(RESET) '
	@printf '(where you are logged into waze.com in Chrome):\n\n'
	@printf '  pip install browser-cookie3\n'
	@printf '  python services/waze-sidecar/scripts/export_cookies.py --out waze_session.json\n\n'
	@printf 'Then copy to the VPS and restart the sidecar:\n\n'
	@printf '  scp waze_session.json root@$(DOMAIN):$(SIDECAR_DIR)/data/waze_session.json\n'
	@printf '  ssh root@$(DOMAIN) "\\\n'
	@printf '    chown waze-sidecar:waze-sidecar $(SIDECAR_DIR)/data/waze_session.json && \\\n'
	@printf '    systemctl restart waze-sidecar"\n\n'
	@printf '$(YELLOW)Repeat this process when the sidecar starts returning 503 errors (~monthly).$(RESET)\n\n'

# ----------------------------------------------------------------------------
# Rollback
# ----------------------------------------------------------------------------

## Show recent commits and instructions for rolling back to a previous version
rollback:
	@printf '$(BOLD)Recent commits$(RESET) (pick a hash to roll back to):\n\n'
	git log --oneline -10
	@printf '\n$(YELLOW)To roll back:$(RESET)\n'
	@printf '  git checkout <commit-hash>\n'
	@printf '  make deploy\n'
	@printf '  git checkout main   # return to tip when ready to re-deploy\n\n'
