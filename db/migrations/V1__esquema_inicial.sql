-- ============================================================
-- 1. Extensiones y tipos
-- ============================================================
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TYPE tipo_alojamiento   AS ENUM ('HOTEL', 'HOSTAL', 'HOSPEDAJE', 'OTRO');
CREATE TYPE rol_usuario        AS ENUM ('USUARIO', 'MODERADOR', 'ADMIN');
CREATE TYPE estado_publicacion AS ENUM ('PENDIENTE', 'APROBADO', 'RECHAZADO', 'OCULTO');
CREATE TYPE estado_operativo   AS ENUM ('ABIERTO', 'POSIBLE_CIERRE', 'CERRADO');
CREATE TYPE franja_estadia     AS ENUM ('H4', 'H6', 'H8', 'H12', 'NOCHE_COMPLETA', 'OTRO');
CREATE TYPE fuente_tarifa      AS ENUM ('ALIADO', 'ADMIN', 'COMUNIDAD');
CREATE TYPE tipo_foto          AS ENUM ('LLEGADA', 'CIERRE');
CREATE TYPE estado_foto        AS ENUM ('PENDIENTE', 'VALIDADA', 'RECHAZADA');
CREATE TYPE estado_reporte     AS ENUM ('PENDIENTE', 'CONFIRMADO', 'DESCARTADO');

-- ============================================================
-- 2. Usuarios y sesiones
-- ============================================================
CREATE TABLE usuarios (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alias                CITEXT NOT NULL UNIQUE,
    email                CITEXT NOT NULL UNIQUE,
    password_hash        TEXT NOT NULL,
    email_verificado_en  TIMESTAMPTZ,
    rol                  rol_usuario NOT NULL DEFAULT 'USUARIO',
    intentos_fallidos    SMALLINT NOT NULL DEFAULT 0,
    bloqueado_hasta      TIMESTAMPTZ,
    activo               BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
    eliminado_en         TIMESTAMPTZ,
    CONSTRAINT alias_formato CHECK (alias ~ '^[A-Za-z0-9_.]{3,30}$'),
    CONSTRAINT email_formato CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

CREATE TABLE sesiones (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id   UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    token_hash   CHAR(64) NOT NULL UNIQUE,
    expira_en    TIMESTAMPTZ NOT NULL,
    revocada_en  TIMESTAMPTZ,
    creada_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sesiones_activas ON sesiones (usuario_id) WHERE revocada_en IS NULL;

-- ============================================================
-- 3. Alojamientos
-- ============================================================
CREATE TABLE alojamientos (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre                 VARCHAR(150) NOT NULL,
    tipo                   tipo_alojamiento NOT NULL,
    ubicacion              GEOGRAPHY(POINT, 4326) NOT NULL,
    direccion              VARCHAR(255) NOT NULL,
    tiene_cochera          BOOLEAN NOT NULL DEFAULT FALSE,
    telefono               VARCHAR(30),
    estado_publicacion     estado_publicacion NOT NULL DEFAULT 'PENDIENTE',
    estado_operativo       estado_operativo NOT NULL DEFAULT 'ABIERTO',
    creado_por             UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    calificacion_promedio  NUMERIC(2,1),
    total_resenas          INTEGER NOT NULL DEFAULT 0,
    creado_en              TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ubicacion_srid CHECK (ST_SRID(ubicacion::geometry) = 4326)
);

CREATE INDEX idx_alojamientos_ubicacion_publica
    ON alojamientos USING GIST (ubicacion)
    WHERE estado_publicacion = 'APROBADO';

-- ============================================================
-- 4. Tipos de habitación y tarifas
-- ============================================================
CREATE TABLE tipos_habitacion (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alojamiento_id  UUID NOT NULL REFERENCES alojamientos(id) ON DELETE CASCADE,
    nombre          VARCHAR(60) NOT NULL,
    capacidad       SMALLINT NOT NULL CHECK (capacidad BETWEEN 1 AND 10),
    UNIQUE (alojamiento_id, nombre)
);

CREATE TABLE tarifas (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo_habitacion_id  UUID NOT NULL REFERENCES tipos_habitacion(id) ON DELETE CASCADE,
    franja              franja_estadia NOT NULL CHECK (franja <> 'OTRO'),
    precio_pen          NUMERIC(8,2) NOT NULL CHECK (precio_pen > 0),
    fuente              fuente_tarifa NOT NULL,
    confianza           SMALLINT NOT NULL DEFAULT 1 CHECK (confianza BETWEEN 0 AND 5),
    registrado_por      UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    vigente_hasta       TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '60 days',
    creado_en           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tarifas_consulta ON tarifas (tipo_habitacion_id, franja, vigente_hasta DESC);

-- ============================================================
-- 5. Catálogo de servicios
-- ============================================================
CREATE TABLE servicios (
    id      SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo  VARCHAR(40) NOT NULL UNIQUE,
    nombre  VARCHAR(60) NOT NULL,
    activo  BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO servicios (codigo, nombre) VALUES
    ('TV',              'Televisor'),
    ('AGUA_CALIENTE',   'Agua caliente'),
    ('NETFLIX',         'Netflix'),
    ('YOUTUBE',         'YouTube'),
    ('WIFI',            'WiFi'),
    ('SILLON_TANTRICO', 'Sillón tántrico'),
    ('JACUZZI',         'Jacuzzi');

-- ============================================================
-- 6. Visitas (validadas con foto de llegada)
-- ============================================================
CREATE TABLE visitas (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id          UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    alojamiento_id      UUID NOT NULL REFERENCES alojamientos(id) ON DELETE CASCADE,
    tipo_habitacion_id  UUID REFERENCES tipos_habitacion(id) ON DELETE SET NULL,
    franja              franja_estadia NOT NULL,
    horas               SMALLINT NOT NULL CHECK (horas BETWEEN 1 AND 72),
    monto_pagado_pen    NUMERIC(8,2) NOT NULL CHECK (monto_pagado_pen > 0),
    llegada_en          TIMESTAMPTZ NOT NULL,
    creado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT horas_coherentes CHECK (
        (franja = 'H4'  AND horas = 4)  OR
        (franja = 'H6'  AND horas = 6)  OR
        (franja = 'H8'  AND horas = 8)  OR
        (franja = 'H12' AND horas = 12) OR
        (franja = 'NOCHE_COMPLETA') OR
        (franja = 'OTRO')
    ),
    CONSTRAINT visita_referencia UNIQUE (id, usuario_id, alojamiento_id)
);

CREATE INDEX idx_visitas_usuario ON visitas (usuario_id, llegada_en DESC);

-- ============================================================
-- 7. Reportes de cierre, fotos y reseñas
-- ============================================================
CREATE TABLE reportes_cierre (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alojamiento_id  UUID NOT NULL REFERENCES alojamientos(id) ON DELETE CASCADE,
    usuario_id      UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    estado          estado_reporte NOT NULL DEFAULT 'PENDIENTE',
    revisado_por    UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    revisado_en     TIMESTAMPTZ
);

CREATE INDEX idx_reportes_pendientes ON reportes_cierre (alojamiento_id) WHERE estado = 'PENDIENTE';

CREATE TABLE fotos (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id         UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    alojamiento_id     UUID NOT NULL REFERENCES alojamientos(id) ON DELETE CASCADE,
    visita_id          UUID,
    reporte_cierre_id  UUID REFERENCES reportes_cierre(id) ON DELETE CASCADE,
    tipo               tipo_foto NOT NULL,
    clave_storage      TEXT NOT NULL UNIQUE,
    sha256             CHAR(64) NOT NULL,
    estado             estado_foto NOT NULL DEFAULT 'PENDIENTE',
    creado_en          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT foto_visita_misma_persona
        FOREIGN KEY (visita_id, usuario_id, alojamiento_id)
        REFERENCES visitas (id, usuario_id, alojamiento_id) ON DELETE CASCADE,
    CONSTRAINT foto_asociada CHECK (
        (tipo = 'LLEGADA' AND visita_id IS NOT NULL AND reporte_cierre_id IS NULL) OR
        (tipo = 'CIERRE'  AND reporte_cierre_id IS NOT NULL AND visita_id IS NULL)
    )
);

CREATE INDEX idx_fotos_visita  ON fotos (visita_id);
CREATE INDEX idx_fotos_reporte ON fotos (reporte_cierre_id);

CREATE TABLE resenas (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visita_id            UUID NOT NULL UNIQUE,
    usuario_id           UUID NOT NULL,
    alojamiento_id       UUID NOT NULL,
    calificacion         SMALLINT NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
    volveria             BOOLEAN NOT NULL,
    comentario           VARCHAR(1000),
    estado_publicacion   estado_publicacion NOT NULL DEFAULT 'PENDIENTE',
    fecha_resena         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT resena_visita_valida
        FOREIGN KEY (visita_id, usuario_id, alojamiento_id)
        REFERENCES visitas (id, usuario_id, alojamiento_id) ON DELETE CASCADE,
    CONSTRAINT una_resena_por_lugar UNIQUE (usuario_id, alojamiento_id)
);

CREATE INDEX idx_resenas_publicas ON resenas (alojamiento_id) WHERE estado_publicacion = 'APROBADO';

CREATE TABLE resena_servicios (
    resena_id    UUID NOT NULL REFERENCES resenas(id) ON DELETE CASCADE,
    servicio_id  SMALLINT NOT NULL REFERENCES servicios(id),
    presente     BOOLEAN NOT NULL,
    PRIMARY KEY (resena_id, servicio_id)
);

-- ============================================================
-- 8. Triggers de validación y estadísticas
-- ============================================================
CREATE OR REPLACE FUNCTION exigir_foto_llegada() RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM fotos
        WHERE visita_id = NEW.id AND tipo = 'LLEGADA' AND estado <> 'RECHAZADA'
    ) THEN
        RAISE EXCEPTION 'La visita % requiere una foto de llegada', NEW.id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_visita_con_foto
    AFTER INSERT ON visitas
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION exigir_foto_llegada();

CREATE OR REPLACE FUNCTION exigir_foto_cierre() RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM fotos
        WHERE reporte_cierre_id = NEW.id AND tipo = 'CIERRE'
    ) THEN
        RAISE EXCEPTION 'El reporte de cierre % requiere una foto', NEW.id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_reporte_con_foto
    AFTER INSERT ON reportes_cierre
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION exigir_foto_cierre();

CREATE OR REPLACE FUNCTION recalcular_estadisticas(p_alojamiento UUID) RETURNS VOID AS $$
BEGIN
    UPDATE alojamientos a
    SET total_resenas         = s.total,
        calificacion_promedio = s.promedio,
        actualizado_en        = now()
    FROM (
        SELECT COUNT(*) AS total,
               ROUND(AVG(calificacion), 1) AS promedio
        FROM resenas
        WHERE alojamiento_id = p_alojamiento
          AND estado_publicacion = 'APROBADO'
    ) s
    WHERE a.id = p_alojamiento;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_actualizar_estadisticas() RETURNS TRIGGER AS $$
BEGIN
    PERFORM recalcular_estadisticas(COALESCE(NEW.alojamiento_id, OLD.alojamiento_id));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER resenas_estadisticas
    AFTER INSERT OR UPDATE OR DELETE ON resenas
    FOR EACH ROW EXECUTE FUNCTION trg_actualizar_estadisticas();

-- ============================================================
-- 9. Administración y auditoría
-- ============================================================
CREATE TABLE auditoria_admin (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id     UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    accion       VARCHAR(60) NOT NULL,
    entidad      VARCHAR(40) NOT NULL,
    entidad_id   UUID,
    detalle      JSONB NOT NULL DEFAULT '{}'::jsonb,
    creado_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_auditoria_admin ON auditoria_admin (admin_id, creado_en DESC);

-- ============================================================
-- 10. Vistas públicas (sin datos de usuario)
-- ============================================================
CREATE VIEW v_alojamientos_publicos AS
SELECT a.id,
       a.nombre,
       a.tipo,
       a.direccion,
       a.tiene_cochera,
       ST_Y(a.ubicacion::geometry) AS latitud,
       ST_X(a.ubicacion::geometry) AS longitud,
       a.calificacion_promedio,
       a.total_resenas,
       a.estado_operativo
FROM alojamientos a
WHERE a.estado_publicacion = 'APROBADO';

CREATE VIEW v_resenas_publicas AS
SELECT r.id,
       r.alojamiento_id,
       'Anónimo'::text AS autor,
       r.calificacion,
       r.volveria,
       r.comentario,
       r.fecha_resena
FROM resenas r
WHERE r.estado_publicacion = 'APROBADO';

CREATE VIEW v_tarifas_vigentes AS
SELECT th.alojamiento_id,
       th.id AS tipo_habitacion_id,
       th.nombre AS tipo_habitacion,
       t.franja,
       t.precio_pen,
       t.fuente,
       t.confianza,
       t.creado_en
FROM tarifas t
JOIN tipos_habitacion th ON th.id = t.tipo_habitacion_id
WHERE t.vigente_hasta > now();

-- ============================================================
-- 11. Eventos de búsqueda (analítica sin datos personales)
-- ============================================================
CREATE TABLE eventos_busqueda (
    id             BIGINT GENERATED ALWAYS AS IDENTITY,
    ocurrido_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
    celda_geohash  VARCHAR(6) NOT NULL,
    hora_local     SMALLINT NOT NULL CHECK (hora_local BETWEEN 0 AND 23),
    dia_semana     SMALLINT NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),
    filtros        JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (id, ocurrido_en)
) PARTITION BY RANGE (ocurrido_en);

CREATE TABLE eventos_busqueda_2026_11 PARTITION OF eventos_busqueda
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

CREATE TABLE eventos_busqueda_2026_12 PARTITION OF eventos_busqueda
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

CREATE INDEX idx_eventos_celda_hora ON eventos_busqueda (celda_geohash, hora_local);