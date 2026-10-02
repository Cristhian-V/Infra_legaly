#!/usr/bin/env bash
# ============================================================================
# deploy.sh — Despliegue automatizado de Legaly
#   orden: validar entorno -> levantar BD -> backup -> migraciones ->
#          build/up de api+web -> healthcheck
#
# La raíz del proyecto (PROYECTO_DIR) se autodetecta como la carpeta padre de
# infra/, por lo que sirve para cualquier ruta. Por ejemplo:
#   Producción: /home/administrador/proyecto_legaly
#   Test:       /home/cumbre_ia/proyecto_legaly
#
#   <PROYECTO_DIR>/
#   ├── Back_Legaly/  Front_Legaly/
#   ├── server_prod.env  server_test.env
#   ├── docker-compose(server prod).yml  docker-compose(server test).yml
#   └── infra/deploy.sh   infra/migraciones/
#
# Uso (desde la raíz del proyecto o desde infra/):
#   ENTORNO=prod ./infra/deploy.sh
#   ENTORNO=test ./infra/deploy.sh
#
# Variables (con default):
#   ENTORNO            prod | test                          (inferido por la ruta)
#   PROYECTO_DIR       raíz del proyecto                    (padre de infra/)
#   ENV_FILE           .env del entorno                     ($PROYECTO_DIR/server_$ENTORNO.env)
#   COMPOSE_FILE       docker-compose del servidor          (autodetectado en $PROYECTO_DIR)
#   MIGRACIONES_DIR    carpeta de migraciones               (<script>/migraciones)
#   BACKUP_DIR         carpeta de respaldos                 (<script>/backups)
#   BACKUP_RETENCION   cantidad de backups a conservar      (7)
#   DB_CONTAINER       contenedor de PostgreSQL             (bd_postgres)
#   DB_SERVICIO        servicio de BD en el compose         (db_legaly)
#   SERVICIOS          servicios de app a construir/levantar (api_legaly web_legaly)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROYECTO_DIR="${PROYECTO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ENTORNO: se puede forzar con ENTORNO=prod|test. Si no se indica, se infiere
# por la ruta del proyecto (los servidores conocidos usan .../cumbre_ia/... para test).
if [ -z "${ENTORNO:-}" ]; then
  case "$PROYECTO_DIR" in
    *cumbre_ia*) ENTORNO="test" ;;
    *)           ENTORNO="prod" ;;
  esac
fi

ENV_FILE="${ENV_FILE:-$PROYECTO_DIR/server_${ENTORNO}.env}"

# Autodetección del compose si no se indicó COMPOSE_FILE
if [ -z "${COMPOSE_FILE:-}" ]; then
  for candidato in \
    "$PROYECTO_DIR/docker-compose.yml" \
    "$PROYECTO_DIR/docker-compose(server ${ENTORNO}).yml" \
    "$PROYECTO_DIR/docker-compose(${ENTORNO}).yml"; do
    if [ -f "$candidato" ]; then COMPOSE_FILE="$candidato"; break; fi
  done
  COMPOSE_FILE="${COMPOSE_FILE:-$PROYECTO_DIR/docker-compose.yml}"
fi

MIGRACIONES_DIR="${MIGRACIONES_DIR:-$SCRIPT_DIR/migraciones}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
BACKUP_RETENCION="${BACKUP_RETENCION:-7}"
DB_CONTAINER="${DB_CONTAINER:-bd_postgres}"
DB_SERVICIO="${DB_SERVICIO:-db_legaly}"
SERVICIOS="${SERVICIOS:-api_legaly web_legaly}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m    ERROR: %s\033[0m\n' "$*" >&2; }

trap 'err "Deploy abortado en la línea $LINENO."' ERR

# --- Comando de compose (v2 o v1) ---
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  err "No se encontró 'docker compose' ni 'docker-compose'."
  exit 1
fi
compose() { "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"; }

# --- 1. Validaciones ---
log "Validando archivos"
[ -f "$ENV_FILE" ]      || { err "No existe ENV_FILE: $ENV_FILE"; exit 1; }
[ -f "$COMPOSE_FILE" ]  || { err "No existe COMPOSE_FILE: $COMPOSE_FILE"; exit 1; }
[ -d "$MIGRACIONES_DIR" ] || { err "No existe MIGRACIONES_DIR: $MIGRACIONES_DIR"; exit 1; }
ok "ENTORNO=$ENTORNO"
ok "PROYECTO_DIR=$PROYECTO_DIR"
ok "ENV_FILE=$ENV_FILE"
ok "COMPOSE_FILE=$COMPOSE_FILE"
ok "MIGRACIONES_DIR=$MIGRACIONES_DIR"

# --- 2. Cargar entorno ---
log "Cargando entorno"
set -a
# shellcheck disable=SC1090
# Se quitan los CR (finales de línea Windows) para que el .env cargue en Linux.
. <(sed 's/\r$//' "$ENV_FILE")
set +a
: "${DB_USER:?Falta DB_USER en el .env}"
: "${DB_NAME:?Falta DB_NAME en el .env}"
ok "DB_USER=$DB_USER  DB_NAME=$DB_NAME"

# --- 3. Levantar la BD y esperar ---
log "Levantando la base de datos ($DB_SERVICIO)"
compose up -d "$DB_SERVICIO"
log "Esperando a que PostgreSQL responda"
for i in $(seq 1 30); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    ok "PostgreSQL listo"
    break
  fi
  if [ "$i" -eq 30 ]; then err "PostgreSQL no respondió a tiempo"; exit 1; fi
  sleep 2
done

# --- 4. Backup ---
log "Generando backup (retención: $BACKUP_RETENCION)"
mkdir -p "$BACKUP_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
DUMP="backup_${DB_NAME}_${TS}.dump"
docker exec -t "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc -f "/tmp/$DUMP" \
  || { err "Falló el pg_dump. Abortando: no se migra sin respaldo."; exit 1; }
docker cp "$DB_CONTAINER:/tmp/$DUMP" "$BACKUP_DIR/$DUMP"
docker exec -t "$DB_CONTAINER" rm -f "/tmp/$DUMP"
ok "Backup creado: $BACKUP_DIR/$DUMP"
ls -1t "$BACKUP_DIR"/backup_*.dump 2>/dev/null | tail -n +$((BACKUP_RETENCION + 1)) | xargs -r rm -f
ok "Retención aplicada (máximo $BACKUP_RETENCION backups)"

# --- 5. Migraciones versionadas ---
log "Aplicando migraciones"
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -c \
  "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, aplicado_en timestamptz NOT NULL DEFAULT now());"

shopt -s nullglob
for archivo in "$MIGRACIONES_DIR"/*.sql; do
  version="$(basename "$archivo")"
  aplicada="$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT 1 FROM schema_migrations WHERE version = '$version'")"
  if [ "$aplicada" = "1" ]; then
    ok "Ya aplicada: $version"
    continue
  fi
  log "Aplicando $version"
  docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$archivo"
  docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q -c \
    "INSERT INTO schema_migrations (version) VALUES ('$version');"
  ok "Registrada: $version"
done

# --- 6. Build y arranque de la API y el frontend ---
log "Construyendo imágenes"
compose build $SERVICIOS
log "Levantando servicios"
compose up -d $SERVICIOS
ok "Servicios arriba: $SERVICIOS"

# --- 7. Healthcheck ---
log "Healthcheck"
if ! command -v curl >/dev/null 2>&1; then
  err "curl no está disponible: se omite el healthcheck"
else
  if [ -n "${VITE_API_URL:-}" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$VITE_API_URL/auth/verify" || echo 000)"
    [ "$code" = "401" ] && ok "API $VITE_API_URL/auth/verify -> 401" \
      || { err "API respondió $code (se esperaba 401)"; exit 1; }
  else
    err "VITE_API_URL no definido: se omite el healthcheck de la API"
  fi
  if [ -n "${CORS_ORIGIN:-}" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "$CORS_ORIGIN" || echo 000)"
    [ "$code" = "200" ] && ok "Front $CORS_ORIGIN -> 200" \
      || { err "Front respondió $code (se esperaba 200)"; exit 1; }
  else
    err "CORS_ORIGIN no definido: se omite el healthcheck del frontend"
  fi
fi

log "Deploy completado"
