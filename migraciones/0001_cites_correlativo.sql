-- Migración 0001 — CITES (correlativo anual + registro de correspondencia)
-- Idempotente: puede ejecutarse varias veces sin error.

BEGIN;

CREATE TABLE IF NOT EXISTS cites_correlativos (
    anio integer PRIMARY KEY,
    ultimo integer NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS cites (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero integer NOT NULL,
    anio integer NOT NULL,
    via character varying(20) NOT NULL,
    ref text,
    destinatario character varying(255),
    cargo_institucion character varying(255),
    creado_por_id integer REFERENCES usuarios(id) ON DELETE SET NULL,
    caso_id integer REFERENCES casos(caso_id) ON DELETE SET NULL,
    documento_id integer REFERENCES documentos(id) ON DELETE SET NULL,
    creado_en timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT cites_via_check CHECK (via IN ('correo', 'entrega física')),
    CONSTRAINT cites_anio_numero_key UNIQUE (anio, numero)
);

INSERT INTO tipos_historial_caso (codigo, nombre)
SELECT 'creacion_cite', 'Creación de CITE'
WHERE NOT EXISTS (SELECT 1 FROM tipos_historial_caso WHERE codigo = 'creacion_cite');

INSERT INTO tipo_documento (nombre)
SELECT 'CITE'
WHERE NOT EXISTS (SELECT 1 FROM tipo_documento WHERE nombre = 'CITE');

COMMIT;

-- Rollback:
-- DROP TABLE IF EXISTS cites;
-- DROP TABLE IF EXISTS cites_correlativos;
-- DELETE FROM tipos_historial_caso WHERE codigo = 'creacion_cite';
-- DELETE FROM tipo_documento WHERE nombre = 'CITE';
