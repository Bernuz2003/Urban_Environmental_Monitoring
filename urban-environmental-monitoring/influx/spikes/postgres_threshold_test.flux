import "sql"
import "influxdata/influxdb/secrets"

// Run this once from Data Explorer after configuring POSTGRES_DSN.
postgresDSN = secrets.get(key: "POSTGRES_DSN")

sql.from(
    driverName: "postgres",
    dataSourceName: postgresDSN,
    query: "SELECT metric, warning_threshold::double precision, critical_threshold::double precision FROM threshold_profile ORDER BY metric",
)
