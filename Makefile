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