# System design

```text
Historical dataset -> Influx CLI -> InfluxDB
Static context     -> PostgreSQL init -> PostgreSQL/PostGIS

Prepared live feed -> Kafka -> Telegraf -> urban_raw
                                         -> raw_to_hourly -> urban_hourly
                                                              |-> hourly_to_daily -> urban_daily
                                                              `-> hourly_to_alerts + PostgreSQL thresholds -> urban_alerts
```

Il repository runtime non contiene generazione statistica e non implementa client HTTP custom. Bucket e Tasks vengono configurati una sola volta tramite InfluxDB UI; i file storici vengono importati con la CLI ufficiale.
