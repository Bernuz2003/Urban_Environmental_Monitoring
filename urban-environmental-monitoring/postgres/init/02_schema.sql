CREATE TABLE IF NOT EXISTS public.grid_context (
    grid_id TEXT PRIMARY KEY,
    cell_code TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL,
    city TEXT NOT NULL,
    borough TEXT NOT NULL,
    zone_type TEXT NOT NULL,
    center_lat DOUBLE PRECISION NOT NULL CHECK (center_lat BETWEEN 40.45 AND 40.95),
    center_lon DOUBLE PRECISION NOT NULL CHECK (center_lon BETWEEN -74.30 AND -73.65),
    green_space_pct DOUBLE PRECISION NOT NULL CHECK (green_space_pct BETWEEN 0 AND 100),
    road_density DOUBLE PRECISION NOT NULL CHECK (road_density BETWEEN 0 AND 1),
    population_density_factor DOUBLE PRECISION NOT NULL CHECK (population_density_factor BETWEEN 0 AND 1),
    estimated_population INTEGER NOT NULL CHECK (estimated_population >= 0),
    cell_area_km2 DOUBLE PRECISION NOT NULL CHECK (cell_area_km2 > 0),
    centroid_geom GEOMETRY(Point, 4326) NOT NULL,
    cell_geom GEOMETRY(MultiPolygon, 4326) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sensor_context (
    sensor_id TEXT PRIMARY KEY,
    grid_id TEXT NOT NULL REFERENCES public.grid_context(grid_id),
    sensor_lat DOUBLE PRECISION NOT NULL CHECK (sensor_lat BETWEEN 40.45 AND 40.95),
    sensor_lon DOUBLE PRECISION NOT NULL CHECK (sensor_lon BETWEEN -74.30 AND -73.65),
    sensor_type TEXT NOT NULL,
    active BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS public.threshold_profile (
    metric TEXT PRIMARY KEY,
    unit TEXT NOT NULL,
    warning_threshold DOUBLE PRECISION NOT NULL,
    critical_threshold DOUBLE PRECISION NOT NULL,
    description TEXT NOT NULL,
    source TEXT NOT NULL,
    CHECK (warning_threshold < critical_threshold)
);

CREATE INDEX IF NOT EXISTS idx_grid_context_borough ON public.grid_context(borough);
CREATE INDEX IF NOT EXISTS idx_grid_context_zone_type ON public.grid_context(zone_type);
CREATE INDEX IF NOT EXISTS idx_grid_context_cell_geom ON public.grid_context USING GIST(cell_geom);
CREATE INDEX IF NOT EXISTS idx_grid_context_centroid_geom ON public.grid_context USING GIST(centroid_geom);
CREATE INDEX IF NOT EXISTS idx_sensor_context_grid_id ON public.sensor_context(grid_id);
