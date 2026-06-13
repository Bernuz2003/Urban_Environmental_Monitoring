-- Static reference data is versioned as CSV and loaded once when the PostgreSQL
-- volume is created. The normal bootstrap does not regenerate zones or sensors.

CREATE TEMP TABLE grid_context_stage (
    grid_id TEXT,
    cell_code TEXT,
    display_name TEXT,
    city TEXT,
    borough TEXT,
    zone_type TEXT,
    center_lat DOUBLE PRECISION,
    center_lon DOUBLE PRECISION,
    green_space_pct DOUBLE PRECISION,
    road_density DOUBLE PRECISION,
    population_density_factor DOUBLE PRECISION,
    estimated_population INTEGER,
    cell_area_km2 DOUBLE PRECISION,
    centroid_wkt TEXT,
    cell_wkt TEXT
);

COPY grid_context_stage
FROM '/dataset/postgres/grid_context.csv'
WITH (FORMAT csv, HEADER true);

INSERT INTO public.grid_context (
    grid_id, cell_code, display_name, city, borough, zone_type,
    center_lat, center_lon, green_space_pct, road_density,
    population_density_factor, estimated_population, cell_area_km2,
    centroid_geom, cell_geom
)
SELECT
    grid_id, cell_code, display_name, city, borough, zone_type,
    center_lat, center_lon, green_space_pct, road_density,
    population_density_factor, estimated_population, cell_area_km2,
    ST_GeomFromText(centroid_wkt, 4326),
    ST_GeomFromText(cell_wkt, 4326)
FROM grid_context_stage
ON CONFLICT (grid_id) DO NOTHING;

COPY public.sensor_context (
    sensor_id, grid_id, sensor_lat, sensor_lon, sensor_type, active
)
FROM '/dataset/postgres/sensor_context.csv'
WITH (FORMAT csv, HEADER true);

COPY public.threshold_profile (
    metric, unit, warning_threshold, critical_threshold, description, source
)
FROM '/dataset/postgres/threshold_profile.csv'
WITH (FORMAT csv, HEADER true);
