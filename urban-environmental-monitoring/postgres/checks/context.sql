SELECT COUNT(*) AS zones FROM grid_context;
SELECT COUNT(*) AS sensors FROM sensor_context;
SELECT metric, warning_threshold, critical_threshold FROM threshold_profile ORDER BY metric;
SELECT COUNT(*) FILTER (WHERE ST_IsValid(cell_geom)) AS valid_geometries, COUNT(*) AS total_geometries FROM grid_context;
