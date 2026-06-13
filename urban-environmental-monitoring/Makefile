SHELL := /bin/bash

.PHONY: bootstrap-core bootstrap-data bootstrap-live status load backfill down ps logs

bootstrap-core:
	./scripts/bootstrap.sh core

bootstrap-data:
	YES="$(YES)" ./scripts/bootstrap.sh data

bootstrap-live:
	DELAY_SECONDS="$(DELAY_SECONDS)" ./scripts/bootstrap.sh live

status:
	./scripts/status.sh

down:
	docker compose down

ps:
	docker compose ps

logs:
	docker compose logs -f --tail=100

load:
	./scripts/load_historical.sh

backfill:
	./scripts/backfill_alerts.sh
