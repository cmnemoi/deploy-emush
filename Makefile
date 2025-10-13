.PHONY: all
all: deploy

.PHONY: deploy
deploy:
	./deploy.sh

.PHONY: deploy-stable
deploy-stable:
	@echo "Deploying stable version (master branch)..."
	./deploy.sh --stable

.PHONY: deploy-beta
deploy-beta:
	@echo "Deploying beta version (develop branch)..."
	./deploy.sh --beta

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
	./deploy.cmnemoi.sh --beta