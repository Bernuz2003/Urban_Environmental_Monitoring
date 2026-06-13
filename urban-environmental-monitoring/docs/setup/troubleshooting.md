# Troubleshooting

## Ripartire da zero

Per eliminare container e volumi del runtime:

```bash
docker compose down -v
```

Il dataset installato in `data/dataset` non viene eliminato da `docker compose down -v`. Se vuoi reinstallarlo:

```bash
rm -rf data/dataset/postgres/* data/dataset/influx/* data/dataset/live/*
rm -f data/dataset/manifest.json data/dataset/checksums.sha256
./scripts/install_dataset.sh ../urban-environmental-data-generator/output/urban-environmental-dataset
```

Poi rilanciare:

```bash
make bootstrap-core
```

## PostgreSQL non contiene dati
Gli script `docker-entrypoint-initdb.d` vengono eseguiti solo con un volume nuovo. Verificare che il dataset sia stato installato prima del primo `docker compose up`. Per ricreare soltanto PostgreSQL: fermare il progetto, eliminare il volume PostgreSQL e riavviare.

## Telegraf restituisce unauthorized
Aggiornare `INFLUX_TOKEN` in `.env` e ricreare il container:

```bash
docker compose up -d --force-recreate telegraf
```

## La Task alert fallisce
Controllare il secret:

```bash
docker compose exec -T influxdb influx secret list --org polito --token "$INFLUX_TOKEN"
```

Controllare inoltre che PostgreSQL sia raggiungibile con hostname `postgres`. Il checkpoint `make bootstrap-data` aggiorna automaticamente `POSTGRES_DSN` e verifica Flux -> PostgreSQL.

## Gli alert live non compaiono subito
Attendere il ciclo delle Tasks (circa un minuto) e controllare la cronologia delle esecuzioni dalla UI InfluxDB.

## Il bootstrap si ferma con un NEXT

I checkpoint non trattano come errore una configurazione manuale mancante. Seguire il messaggio `NEXT`, completare il passaggio indicato e rilanciare lo stesso comando.
