WITH u AS (
    INSERT INTO usuarios (alias, email, password_hash)
    VALUES ('admin_prueba', 'admin@ejemplo.pe', 'hash_de_prueba')
    ON CONFLICT (alias) DO UPDATE SET alias = EXCLUDED.alias
    RETURNING id
),
a AS (
    INSERT INTO alojamientos (nombre, tipo, ubicacion, direccion, tiene_cochera, estado_publicacion, creado_por)
    SELECT 'Hostal Prueba', 'HOSTAL',
           ST_SetSRID(ST_MakePoint(-77.0364, -12.0931), 4326)::geography,
           'Av. Prueba 123, San Isidro', TRUE, 'APROBADO', u.id
    FROM u
    RETURNING id
),
th AS (
    INSERT INTO tipos_habitacion (alojamiento_id, nombre, capacidad)
    SELECT a.id, 'Doble', 2 FROM a
    RETURNING id
)
INSERT INTO tarifas (tipo_habitacion_id, franja, precio_pen, fuente)
SELECT th.id, 'H4', 40.00, 'ADMIN' FROM th;
