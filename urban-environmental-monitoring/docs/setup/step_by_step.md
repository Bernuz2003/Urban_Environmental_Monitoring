# Setup completo passo per passo

Il runtime usa checkpoint piccoli e leggibili. Ogni checkpoint puo essere rilanciato: se manca un prerequisito, stampa il prossimo passo invece di avviare un setup incompleto.

## 1. Generare il dataset

Nel repository esterno:

```bash
cd urban-environmental-data-generator
make generate
```

L'output si trova in `output/urban-environmental-dataset`.

## 2. Installare dataset e file `.env`

Nel repository runtime:

```bash
cd ../urban-environmental-monitoring
./scripts/install_dataset.sh ../urban-environmental-data-generator/output/urban-environmental-dataset
cp .env.example .env
```

Se il dataset non e ancora disponibile, `make bootstrap-core` non fallisce con errori distruttivi: stampa le istruzioni per generarlo e installarlo.

## 3. Avviare il core

```bash
make bootstrap-core
```

Il checkpoint:

- verifica `.env`;
- verifica il dataset installato e i checksum;
- valida `docker-compose.yml`;
- avvia PostgreSQL, InfluxDB e Grafana;
- attende i servizi;
- legge il contesto statico PostgreSQL.

PostgreSQL carica il contesto statico soltanto alla prima creazione del volume. Se vuoi ripartire da zero, elimina i volumi come indicato in `docs/setup/troubleshooting.md`.

## 4. Setup InfluxDB via UI

Aprire `http://localhost:8086` e completare il setup iniziale:

- username e password a scelta;
- organization: `polito`;
- initial bucket: `urban_raw`;
- copiare l'Operator token e inserirlo in `.env` come `INFLUX_TOKEN`.

Dalla UI impostare la retention di `urban_raw` a **35 giorni** e creare:

| Bucket | Retention |
|---|---:|
| `urban_hourly` | 366 giorni |
| `urban_daily` | 1098 giorni |
| `urban_alerts` | 366 giorni |

## 5. Creare le InfluxDB Tasks dalla UI

In **Data > Tasks**, creare tre Tasks copiando integralmente:

1. `influx/tasks/raw_to_hourly.flux`;
2. `influx/tasks/hourly_to_daily.flux`;
3. `influx/tasks/hourly_to_alerts.flux`.

Prima di salvare, verificare che `org: "polito"` corrisponda all'organizzazione scelta.

Il secret `POSTGRES_DSN` e il test Flux -> PostgreSQL vengono gestiti automaticamente da `make bootstrap-data`.

## 6. Caricare dati storici e derivare alert

```bash
make bootstrap-data
```

Il checkpoint:

- verifica token, org e bucket InfluxDB;
- configura o aggiorna il secret `POSTGRES_DSN`;
- verifica che Flux riesca a leggere `threshold_profile` in PostgreSQL;
- verifica che le tre Tasks esistano;
- carica `urban_raw`, `urban_hourly` e `urban_daily` con precisione `us`;
- esegue il backfill di `urban_alerts`;
- stampa conteggi principali.


## 7. Avviare live ingestion e replay

```bash
make bootstrap-live
```

Il checkpoint:

- avvia Kafka;
- crea il topic `urban.telemetry` se manca;
- avvia Telegraf;
- pubblica i quattro batch live;
- stampa offset Kafka, lag consumer e log recenti Telegraf.


I quattro batch vengono pubblicati su Kafka con timestamp appartenenti all'ultima ora completa. Telegraf li scrive in `urban_raw`. Entro circa un minuto, le Tasks aggiornano `urban_hourly` e `urban_alerts`.

## 8. Controllo

```bash
make status
```

Mostra:

- stato dei container;
- conteggi PostgreSQL;
- bucket e Tasks InfluxDB;
- conteggi principali InfluxDB;
- topic, offset e lag Kafka;
- log recenti Telegraf.

## 9. Grafana

Aprire `http://localhost:3000`, credenziali iniziali da `.env`. In questa fase non esiste ancora una dashboard definitiva. I datasource saranno configurati manualmente nella fase query/dashboard.

Usare gli hostname interni Docker:

- InfluxDB: `http://influxdb:8086`;
- PostgreSQL: `postgres:5432`.

## 10. Riavvio ordinario

Dopo il setup iniziale:

```bash
docker compose up -d
make status
```

I volumi conservano dati, bucket, Tasks e configurazioni. Non rigenerare ne ricaricare lo storico, salvo quando vuoi reinizializzare esplicitamente il sistema.
