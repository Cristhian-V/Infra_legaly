# infra-legaly

Infraestructura de despliegue de Legaly: migraciones de base de datos y script de deploy.

## Contenido

```
infra/
├── deploy.sh              # backup + migraciones + build/up + healthcheck
├── migraciones/           # migraciones versionadas (idempotentes)
│   ├── 0001_cites_correlativo.sql
│   └── 0002_tipos_evento_creado_por.sql
├── backups/               # (gitignored) respaldos pg_dump
└── README.md
```

## Requisitos en el servidor

- Docker con `docker compose` (v2) o `docker-compose` (v1).
- El `docker-compose.yml` del servidor y el `.env` del entorno (no versionados).
- `curl` (para el healthcheck).

## Uso

El proyecto conserva esta misma estructura en cada servidor (`infra/` cuelga de la raíz):

| Entorno | Raíz del proyecto                          |
|---------|--------------------------------------------|
| prod    | `/home/administrador/proyecto_legaly`      |
| test    | `/home/cumbre_ia/proyecto_legaly`          |

Desde la raíz del proyecto correspondiente:

```bash
# Producción (en /home/administrador/proyecto_legaly)
ENTORNO=prod ./infra/deploy.sh

# Test (en /home/cumbre_ia/proyecto_legaly)
ENTORNO=test ./infra/deploy.sh
```

`deploy.sh` **deduce la raíz del proyecto** (carpeta padre de `infra/`) y **infiere el
entorno** por la ruta (`.../cumbre_ia/...` → `test`; cualquier otra → `prod`). No hay
rutas hardcodeadas y localiza automáticamente `server_<entorno>.env` y el
`docker-compose(server <entorno>).yml`.

En el server de test, por lo tanto, basta con:

```bash
cd /home/cumbre_ia/proyecto_legaly
./infra/deploy.sh          # infiere ENTORNO=test
```

`ENTORNO` siempre se puede forzar: `ENTORNO=prod ./infra/deploy.sh`.

## Variables

| Variable            | Default                              | Descripción                          |
|---------------------|--------------------------------------|--------------------------------------|
| `ENTORNO`           | `prod`                               | `prod` o `test`                      |
| `PROYECTO_DIR`      | padre de `infra/`                    | raíz del proyecto                    |
| `ENV_FILE`          | `server_$ENTORNO.env` o `.env`       | `.env` del entorno                   |
| `COMPOSE_FILE`      | autodetectado en `$PROYECTO_DIR`     | compose del servidor                 |
| `MIGRACIONES_DIR`   | `<script>/migraciones`               | carpeta de migraciones               |
| `BACKUP_DIR`        | `<script>/backups`                   | carpeta de respaldos                 |
| `BACKUP_RETENCION`  | `7`                                  | respaldos a conservar                |
| `DB_CONTAINER`      | `bd_postgres`                        | contenedor de PostgreSQL             |
| `DB_SERVICIO`       | `db_legaly`                          | servicio de BD en el compose         |
| `SERVICIOS`         | `api_legaly web_legaly`              | servicios de app a construir/levantar|
| `HEALTH_API_URL`    | `$VITE_API_URL/auth/verify`          | URL de healthcheck de la API (espera 401) |
| `HEALTH_FRONT_URL`  | `$CORS_ORIGIN`                       | URL de healthcheck del frontend (espera 200) |

## Cómo funciona

1. Valida que existan `ENV_FILE`, `COMPOSE_FILE` y `MIGRACIONES_DIR`.
2. Levanta la BD y espera `pg_isready`.
3. Genera un backup `pg_dump -Fc` y aplica retención.
4. Crea `schema_migrations` si no existe y aplica **solo** las migraciones pendientes.
5. Construye y levanta `api_legaly` y `web_legaly`.
6. Healthcheck: `GET $VITE_API_URL/auth/verify` → 401 y `GET $CORS_ORIGIN` → 200.

No hace `git pull` (la actualización de código es manual) y no levanta Collabora.

## Rollback

- Cada migración incluye su bloque de reversa comentado al final del archivo.
- Restauración completa: usar el `.dump` más reciente de `backups/` con `pg_restore`.
