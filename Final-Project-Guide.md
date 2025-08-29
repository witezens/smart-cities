# Guía del proyecto final — Ciudades inteligentes

**Versión:** 1.0 
**Última actualización:** 23/08/2025 13:33 
**Profesor:** Wilmer Tezén
**Tema:** Arquitectura II

> **Objetivo.** Esta guía le proporciona un plan completo y estandarizado para crear un sistema simulado, distribuido y en tiempo real de supervisión perimetral. Utilice el **evento canónico (normalizado)**, el **Event Ingestor** como primer paso y un sólido canal de **transmisión + correlación**.

## 0) Big Picture (End‑to‑End)
```
[Simulators: Ingest tools]
           ↓ HTTP (JSON canonical)
  [Event Ingestor REST]
           ↓ Kafka (topic: events.standardized)
  [Correlator (Kafka consumer) + Redis]
           ↓ Kafka (topic: correlated.alerts)
  [Persistence: PostgreSQL (SQL) / Elasticsearch (search)]
           ↓
          Grafana (dashboards, heatmaps, timelines)
```
**Backbone:** Kafka.  
**Contract-first:** todos los mensajes deben cumplir con el **evento canónico 1.0** antes de entrar en Kafka.

---

## 1) Topología de LAN y despliegue (solo red local)
**Objetivo:** aislar las preocupaciones, reproducir una configuración realista de múltiples nodos, mantener la WAN fuera del alcance para evitar la latencia externa.

### 1.1 Plan de VLAN (ejemplo)
- **VLAN 10 – Núcleo/Servicios**: Kafka, Zookeeper, Redis, PostgreSQL, Elasticsearch, Airflow
  - CIDR: `10.10.10.0/24` (puerta de enlace `10.10.10.1`)
- **VLAN 20 – Aplicaciones**: Event Ingestor, Correlator, consumidores ETL
  - CIDR: `10.10.20.0/24` (puerta de enlace `10.10.20.1`)
- **VLAN 30 – Estudiantes/Simuladores**: Generadores Artillery/JMeter/Python
  - CIDR: `10.10.30.0/24` (puerta de enlace `10.10.30.1`)
- **VLAN 40 – Observabilidad (opcional)**: Grafana/admin
  - CIDR: `10.10.40.0/24` (puerta de enlace `10.10.40.1`)

**Enrutamiento entre VLAN y ACL:** permitir 30→20 (HTTP a Ingestor), 20→10 (Kafka/DB), 40→10/20 (solo lectura para paneles).

> **Entregable A1:** diagrama LAN físico/lógico con IP, VLAN, puertas de enlace y funciones de los nodos.



---

## 2) Evento canónico (estándar normalizado) — **OBLIGATORIO**
Cada tipo de sensor/evento debe estar envuelto por la envoltura que se muestra a continuación. Las horas se expresan en **UTC ISO‑8601**. Todas las cadenas están en **lower_snake_case**.

### 2.1 Envelope (common)
```json
{
  "event_version": "1.0",
  "event_type": "panic.button | sensor.lpr | sensor.speed | sensor.acoustic | citizen.report",
  "event_id": "uuid-v4",
  "producer": "artillery | python-sim | kafka-cli",
  "source": "simulated",
  "correlation_id": "uuid-v4",
  "trace_id": "uuid-v4",
  "timestamp": "2025-08-23T12:34:56.789Z",
  "partition_key": "zone_4 | XYZ123 | ...",
  "geo": { "zone": "zone_4", "lat": 14.628, "lon": -90.522 },
  "severity": "info | warning | critical",
  "payload": { }
}
```

### 2.2 Payload by sensor
- **Panic button**
  ```json
  "payload": {
    "tipo_de_alerta": "panico | emergencia | incendio",
    "identificador_dispositivo": "BTN-001",
    "user_context": "movil | quiosco | web"
  }
  ```
- **LPR camera**
  ```json
  "payload": {
    "placa_vehicular": "XYZ123",
    "velocidad_estimada": 85,
    "modelo_vehiculo": "sedan",
    "color_vehiculo": "rojo",
    "ubicacion_sensor": "blvd_las_americas_01"
  }
  ```
- **Speed/motion**
  ```json
  "payload": {
    "velocidad_detectada": 92,
    "sensor_id": "SPD-017",
    "direccion": "NORTE"
  }
  ```
- **Acoustic/ambient**
  ```json
  "payload": {
    "tipo_sonido_detectado": "disparo | explosion | vidrio_roto",
    "nivel_decibeles": 112,
    "probabilidad_evento_critico": 0.83
  }
  ```
- **Citizen report**
  ```json
  "payload": {
    "tipo_evento": "accidente | incendio | altercado",
    "mensaje_descriptivo": "vehiculo volcado",
    "ubicacion_aproximada": "zona_10",
    "origen": "usuario | app | punto_fisico"
  }
  ```

  ### 2.3 Esquema JSON (v1.0)
> Validar en **productor** y nuevamente en **consumidor** (defensa en profundidad). Considerar Avro+Schema Registry como una opción avanzada.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.edu/canonical-event/1-0.schema.json",
  "title": "CanonicalEventV1",
  "type": "object",
  "required": ["event_version","event_type","event_id","producer","source","timestamp","partition_key","geo","severity","payload"],
  "properties": {
    "event_version": {"type":"string","const":"1.0"},
    "event_type": {"type":"string","enum":["panic.button","sensor.lpr","sensor.speed","sensor.acoustic","citizen.report"]},
    "event_id": {"type":"string"},
    "producer": {"type":"string"},
    "source": {"type":"string","enum":["simulated"]},
    "correlation_id": {"type":"string"},
    "trace_id": {"type":"string"},
    "timestamp": {"type":"string","format":"date-time"},
    "partition_key": {"type":"string"},
    "geo": {
      "type":"object",
      "required":["zone"],
      "properties": {
        "zone": {"type":"string"},
        "lat": {"type":"number"},
        "lon": {"type":"number"}
      }
    },
    "severity": {"type":"string","enum":["info","warning","critical"]},
    "payload": {"type":"object"}
  },
  "additionalProperties": false
}
```

> **Entregable A2:** publicar este esquema en el repositorio de la clase; los productores DEBEN validarlo.

---

## 3) Ingestor de eventos (REST) — **LO PRIMERO QUE HAY QUE CONSTRUIR**
**Función:** punto de entrada único para todos los eventos simulados a través de HTTP; aplica el esquema, enriquece los metadatos y publica en Kafka.


### 3.1 API Contract
**Endpoints**
| Method | Path            | Purpose                                      |
|-------:|-----------------|----------------------------------------------|
| POST   | `/events`       | Ingest one event (canonical JSON)            |
| POST   | `/events/bulk`  | Ingest array of events                       |
| GET    | `/health`       | Liveness/readiness                           |
| GET    | `/schema`       | Returns current canonical schema (v1.0)      |

**Respuestas**
- `202 Accepted` si la publicación en Kafka se realiza correctamente
- `400 Bad Request` si se produce un error en la validación del esquema (lista de campos)
- `429 Too Many request` si se alcanza el límite de frecuencia (opcional)
- `500 Internal Server Error` si se produce un fallo inesperado

**Validación y enriquecimiento**
- Aplicar **JSON Schema v1.0**.
- Asegurarse de que **`timestamp` sea UTC/ISO‑8601**; si no existe, establecer la hora del servidor.
- Asegúrese de que **`trace_id`/`correlation_id`** existan; genere automáticamente UUID si faltan.
- Rellene **`partition_key`** si es posible (por ejemplo, `geo.zone` o `payload.placa_vehicular`).

**Política DLQ**
- Cargas útiles no válidas → **NO** publicar en el tema principal. Opcionalmente, publicar el error en `events.dlq` con el motivo.

### 3.2 Pseudocode (Java/Spring)
```java
@PostMapping("/events")
public ResponseEntity<?> ingest(@RequestBody String body) {
  var result = schemaValidator.validate(body);
  if (!result.isValid()) return ResponseEntity.badRequest().body(result.errors());
  var enriched = enricher.apply(body); // add trace_id, correlation_id, ts, partition_key
  var key = keyExtractor.apply(enriched); // e.g., geo.zone
  kafkaTemplate.send("events.standardized", key, enriched);
  return ResponseEntity.accepted().build();
}
```

### 3.3 Artillery → Ingestor (example)
```yaml
config:
  target: "http://ingestor.local:8080"
  phases: [{ duration: 60, arrivalRate: 5 }]
  defaults: { headers: { content-type: application/json } }
scenarios:
  - name: panic-button
    flow:
      - post:
          url: "/events"
          json:
            event_version: "1.0"
            event_type: "panic.button"
            event_id: "{{ $uuid }}"
            producer: "artillery"
            source: "simulated"
            correlation_id: "{{ $uuid }}"
            trace_id: "{{ $uuid }}"
            timestamp: "{{ $isoDate }}"
            partition_key: "zone_4"
            geo: { zone: "zone_4", lat: 14.62, lon: -90.52 }
            severity: "critical"
            payload: { tipo_de_alerta: "panico", identificador_dispositivo: "BTN-001", user_context: "movil" }
```

> **Deliverable A3:** Swagger/Redoc or Markdown con el request/response ejemplos.

---


## 4) Diseño de Kafka
**Temas**
- `events.raw` (opcional): si los equipos desean enviar mensajes preestandarizados
- `events.standardized`: eventos canónicos (primarios)
- `events.dlq`: errores de validación/publicación (opcional)
- `correlated.alerts`: salida de Correlator

**Particiones y claves**
- `key = partition_key` → afinidad por zona o placa.
- Comience con **3-6 particiones** (escala de laboratorio).

**Retención**
- `events.standardized`: 24-72 h
- `correlated.alerts`: 7-30 d

**Configuraciones recomendadas del agente (laboratorio)**
- `num.partitions=3..6`
- `log.retention.hours=72`
- `message.max.bytes=1048576` (ajustar si es necesario)
- Productor: `enable.idempotence=true`, `acks=all` (publicaciones más seguras)

> **Entrega A4:** Capturas de pantalla de la CLI de la creación de temas, el recuento de particiones y una muestra de la salida de `kafka-console-consumer`.


---

## 5) Correlator (Stream Processor) + Redis
**Model:** Consumidor Kafka → correlaciona eventos dentro de **ventanas de tiempo**, mantiene el estado transitorio en **Redis** y genera alertas.

### 5.1 Rules (ejemplos iniciales)
- **Similar a un robo:** `panic.button` en `zone` + `sensor.lpr` con `velocidad_estimada > 80` en la misma `zone` dentro de **±2 min**.
- **Accident:** `citizen.report` tipo `accidente` + `sensor.acoustic` = `explosion`/`vidrio_roto` + Caída repentina de velocidad en LPR cercano dentro de **5 min**.

**Alerta salida (para `correlated.alerts`)**
```json
{
  "alert_id": "uuid-v4",
  "correlation_id": "uuid-v4",
  "type": "possible_robbery | accident",
  "score": 0.85,
  "zone": "zone_4",
  "window": { "start": "...", "end": "..." },
  "evidence": ["event_id_1","event_id_2","event_id_3"],
  "created_at": "UTC ISO-8601"
}
```

### 5.2 Redis state design
- Keys: `corr:zone:{zone}`, `corr:plate:{placa}`
- Valor: pequeña lista de resúmenes de eventos recientes (`event_type`, `ts`, carga útil esencial)
- TTL por clave: **5-10 min** (ventana de coincidencia)
- Idempotencia: mantener un **seen:set** con TTL para `event_id`

### 5.3 Management API (opcional)
- `GET /alerts/active?zone=zone_4`
- `GET /metrics` (Prometheus), `GET /health`
- `PUT /rules` (hot‑reload basic thresholds)

---
