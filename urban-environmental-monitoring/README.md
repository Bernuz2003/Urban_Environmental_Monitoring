# Urban Environmental Monitoring

Repository runtime.

- PostgreSQL/PostGIS: contesto statico, geometrie, sensori e soglie;
- InfluxDB: `urban_raw`, `urban_hourly`, `urban_daily`, `urban_alerts`;
- Kafka + Telegraf: ingestion real-time;
- InfluxDB Tasks: downsampling e alert dinamici;
- Grafana: dashboard, da progettare nella fase successiva.

La generazione del dataset è separata nel repository `urban-environmental-data-generator`.

`make bootstrap-live` avvia un producer continuo che pubblica una lettura per
sensore ogni minuto. Usare `make live-logs` per seguirlo e `make stop-live` per
fermarlo.

La procedura completa è in [`docs/setup/step_by_step.md`](docs/setup/step_by_step.md).
