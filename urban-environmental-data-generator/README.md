# Urban Environmental Data Generator

Repository **esterno** al progetto runtime. Genera una sola volta il dataset usato dalla demo.

## Avvio rapido

```bash
./scripts/generate_dataset.sh           # dataset completo
```

L'output finale è `output/urban-environmental-dataset/` e contiene:

- contesto PostgreSQL in CSV;
- `urban_raw.lp.gz`, `urban_hourly.lp.gz`, `urban_daily.lp.gz`;
- quattro batch live Line Protocol senza timestamp;
- manifest e checksum.

I timestamp dei file storici Line Protocol sono codificati esplicitamente in microsecondi (`us`).

`urban_alerts` non viene generato: sarà derivato nel sistema runtime da InfluxDB e PostgreSQL.

## Verifica

```bash
./scripts/verify_dataset.sh
```

Il generatore è un progetto upstream separato: il repository runtime non dipende dal suo codice.
