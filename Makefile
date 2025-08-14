.PHONY: all
all: deploy

.PHONY: deploy
deploy:
	./deploy.sh

.PHONY: hard-reset
hard-reset:
	docker compose down --volumes --remove-orphans
	rm -rf .env eternaltwin.local.toml
	./deploy.sh

.PHONY: restart
restart:
	docker compose down --remove-orphans
	docker compose up --force-recreate --remove-orphans -d --wait --wait-timeout 15