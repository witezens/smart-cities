#!/usr/bin/env bash
set -euo pipefail

BOOT=kafka-1:9092

# ------------------------------------------------------------------------------------
# TOPICS CLAVE PARA SMART CITIES
# - events.raw:           entrada cruda desde sensores/ingestores (opcional)
# - events.standardized:  único formato normalizado para todos los eventos
# - events.enriched:      eventos enriquecidos (geofencing, censos, catastro, etc.)
# - events.alerts:        alertas generadas (reglas, umbrales, correlación)
# - events.alerts.dlq:    fallas al procesar/generar alertas (Dead Letter Queue)
# - ref.*:                datos de referencia (compaction) p.ej. catálogo de sensores
# ------------------------------------------------------------------------------------

# nombre:particiones:retencion_ms:cleanup_policy
TOPICS=(
  "events.raw:6:604800000:delete"            # 7 días
  "events.standardized:12:1209600000:delete" # 14 días (núcleo del dominio)
  "events.enriched:12:1209600000:delete"     # 14 días
  "events.alerts:6:5184000000:delete"        # 60 días (útil para auditoría/analítica)
  "events.alerts.dlq:6:1209600000:delete"    # 14 días
  "ref.sensors:3:-1:compact"                 # compacted: estado actual de sensores
  "ref.zones:3:-1:compact"                   # compacted: zonas / polígonos
)

echo "==> Creando topics"
for def in "${TOPICS[@]}"; do
  IFS=":" read -r name parts retention policy <<<"$def"
  EXTRA=()
  if [[ "$retention" != "-1" ]]; then
    EXTRA+=(--config retention.ms="$retention")
  fi
  if [[ "$policy" == "compact" ]]; then
    EXTRA+=(--config cleanup.policy=compact)
  else
    EXTRA+=(--config cleanup.policy=delete)
  fi

  echo " - $name (partitions=$parts, retention=${retention}, policy=${policy})"
  kafka-topics --bootstrap-server "$BOOT" --create \
    --if-not-exists --topic "$name" --partitions "$parts" --replication-factor 1 \
    "${EXTRA[@]}"
done

echo "==> Listado de topics:"
kafka-topics --bootstrap-server "$BOOT" --list

# Sugerencia de claves y headers (no ejecuta nada, solo documentación):
cat <<'DOC'

=== Recomendaciones de clave (key) y headers ===
Key (para particionado estable):
  key = "${cityId}:${sensorId}"  (ej. "GUA-001:CAM-12345")

Headers sugeridos:
  source=ingestor-name           # ej. edge-gw-01, traffic-ingestor
  schemaVersion=1                # versión del JSON normalizado
  eventType=traffic|noise|env|security|lighting|parking|other
  cityId=GUA-001
  sensorType=camera|mic|weather|lidar|parking-meter
  contentEncoding=json

DOC
