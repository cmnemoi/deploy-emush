.PHONY: all
all: deploy

.PHONY: deploy
deploy:
	./deploy.sh

.PHONY: hard-reset
hard-reset:
	rm -rf .env eternaltwin.local.toml
	docker compose down --volumes --remove-orphans
	./deploy.sh