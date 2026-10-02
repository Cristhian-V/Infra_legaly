-- Migración 0002 — Tipos de evento por usuario (autoría)
-- Agrega el autor del tipo de evento; NULL representa un tipo global.
-- Idempotente: puede ejecutarse varias veces sin error.

BEGIN;

ALTER TABLE tipos_evento_cal
    ADD COLUMN IF NOT EXISTS creado_por_id integer REFERENCES usuarios(id) ON DELETE SET NULL;

COMMIT;

-- Rollback:
-- ALTER TABLE tipos_evento_cal DROP COLUMN IF EXISTS creado_por_id;
