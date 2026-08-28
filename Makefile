.PHONY: all
all: deploy

.PHONY: deploy
deploy:
	./deploy.sh

.PHONY: deploy-main
deploy-main:
	@echo "Deploying main branch..."
	./deploy.sh --main

.PHONY: deploy-legacy
deploy-legacy:
	@echo "Deploying legacy branch..."
	./deploy.sh --legacy

.PHONY: hard-reset
hard-reset:
	docker compose down --volumes --remove-orphans
	rm -rf .env eternaltwin.local.toml
	./deploy.sh

.PHONY: restart
restart:
	docker compose down --remove-orphans
	docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15

deploy-cmnemoi:
	./deploy.cmnemoi.sh --main