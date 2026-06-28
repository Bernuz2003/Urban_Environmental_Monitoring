SHELL := /bin/bash

.PHONY: bootstrap-core bootstrap-data bootstrap-live stop-live live-logs status load backfill down ps logs

bootstrap-core:
	./scripts/bootstrap.sh core

bootstrap-data:
	YES="$(YES)" ./scripts/bootstrap.sh data

bootstrap-live:
	LIVE_INTERVAL_SECONDS="$(LIVE_INTERVAL_SECONDS)" ./scripts/bootstrap.sh live

stop-live:
	docker compose stop live-producer

live-logs:
	docker compose logs -f --tail=50 live-producer

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
