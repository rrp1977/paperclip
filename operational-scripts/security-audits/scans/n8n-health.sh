#!/usr/bin/env bash
# scan-n8n-health.sh — auditoria self-health de n8n: workflows con errores 24h + uptime container.
# Output JSON Lines.
#
# Fix 2026-04-18: Ejecuta comandos Docker LOCAL cuando el scan corre en el propio VPS (evita
# falsos positivos por "Host key verification failed" al hacer ssh al propio host). Retry 3x
# antes de declarar container caído (ventana de tolerancia para restarts transitorios).
set -euo pipefail

VPS_HOST="${VPS_HOST:-root@161.97.187.244}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
N8N_URL="${N8N_URL:-https://v2n8n.soludigitalpro.com}"

# Detecta si estamos corriendo EN el propio VPS (evita ssh a sí mismo → Host key verification failed)
THIS_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || hostname -i 2>/dev/null || echo "")
TARGET_IP=$(echo "$VPS_HOST" | sed 's/.*@//')
LOCAL_MODE=false
if [ "$THIS_IP" = "$TARGET_IP" ] || [ -S /var/run/docker.sock ]; then
  LOCAL_MODE=true
fi

remote() {
  if [ "$LOCAL_MODE" = "true" ]; then
    bash -c "$1" 2>/dev/null || echo ""
  else
    ssh $SSH_OPTS "$VPS_HOST" "$1" 2>/dev/null || echo ""
  fi
}

# --- 1. n8n container status (retry 3x con 2s backoff) ---
CONTAINER_STATE=""
for attempt in 1 2 3; do
  CONTAINER_STATE=$(remote 'docker inspect n8n --format "{{.State.Status}}" 2>/dev/null || echo "missing"')
  case "$CONTAINER_STATE" in
    running|restarting|created)
      break
      ;;
    *)
      [ "$attempt" -lt 3 ] && sleep 2
      ;;
  esac
done

if [ "$CONTAINER_STATE" != "running" ] && [ "$CONTAINER_STATE" != "restarting" ]; then
  jq -c -n --arg src "n8n-self-health" --arg state "${CONTAINER_STATE:-unknown}" \
    '{source:$src, severity:"CRITICAL", title:"n8n container not running", description:"docker inspect n8n State.Status = \($state) tras 3 reintentos. Workflows caidos.", metadata:{state:$state, retries:3}}'
  exit 0  # Sin container, no podemos seguir
fi

# Restart transitorio = MEDIUM, no CRITICAL
if [ "$CONTAINER_STATE" = "restarting" ]; then
  jq -c -n --arg src "n8n-self-health" \
    '{source:$src, severity:"MEDIUM", title:"n8n container en restart transitorio", description:"State.Status=restarting tras 3 reintentos. Posible crash loop, verificar en 5min.", metadata:{state:"restarting"}}'
fi

# --- 2. HTTP responsiveness ---
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -m 10 "$N8N_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "401" ] && [ "$HTTP_CODE" != "404" ]; then
  jq -c -n --arg src "n8n-self-health" --arg code "$HTTP_CODE" --arg url "$N8N_URL" \
    '{source:$src, severity:"HIGH", title:"n8n HTTP \($code) en \($url)", description:"n8n frontend no responde 2xx/4xx (401/404 son OK sin auth). Posible crash o DNS roto.", metadata:{url:$url, http_code:$code}}'
fi

# --- 3. Errores en logs últimas 24h ---
ERROR_COUNT=$(remote 'docker logs n8n --since 24h 2>&1 | grep -ciE "error|failed|timeout" || echo 0')
ERROR_COUNT=${ERROR_COUNT:-0}

# --- 3.5 Breakdown top-5 workflows con errores 24h ---
# Primary: n8n REST API (precisión alta, requiere N8N_API_KEY/URL en VPS env).
# Fallback: parse docker logs por nombres de workflow (precisión baja pero zero-dep).
BREAKDOWN_JSON="[]"
if [ "$ERROR_COUNT" -gt 0 ]; then
  if [ -n "${N8N_API_KEY:-}" ] && [ -n "${N8N_API_URL:-}" ]; then
    EXEC_JSON=$(curl -sS -m 15 -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_API_URL%/}/executions?status=error&limit=100" 2>/dev/null || echo "")
    if echo "$EXEC_JSON" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
      CUTOFF=$(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || echo "")
      GROUPED=$(echo "$EXEC_JSON" | jq --arg cutoff "$CUTOFF" -c '
        [.data[] | select($cutoff == "" or .startedAt >= $cutoff)]
        | group_by(.workflowId)
        | map({workflowId: (.[0].workflowId // "unknown"), errors: length})
        | sort_by(-.errors) | .[0:5]' 2>/dev/null || echo "[]")
      RESOLVED="[]"
      for row in $(echo "$GROUPED" | jq -c '.[]' 2>/dev/null); do
        WID=$(echo "$row" | jq -r '.workflowId')
        WERR=$(echo "$row" | jq -r '.errors')
        if [ "$WID" = "unknown" ] || [ -z "$WID" ]; then
          WNAME="unknown"
        else
          WNAME=$(curl -sS -m 10 -H "X-N8N-API-KEY: $N8N_API_KEY" \
            "${N8N_API_URL%/}/workflows/${WID}" 2>/dev/null \
            | jq -r '.name // .data.name // "unknown"' 2>/dev/null || echo "unknown")
        fi
        RESOLVED=$(echo "$RESOLVED" | jq --arg n "$WNAME" --argjson e "$WERR" \
          '. + [{workflow:$n, errors:$e}]' 2>/dev/null || echo "$RESOLVED")
      done
      BREAKDOWN_JSON="$RESOLVED"
    fi
  fi

  # Fallback: grep docker logs por patrones de workflow names
  if [ "$BREAKDOWN_JSON" = "[]" ]; then
    BREAKDOWN_JSON=$(remote 'docker logs n8n --since 24h 2>&1' \
      | grep -iE "error|failed|timeout" \
      | grep -oE '"workflowName":"[^"]+"|"name":"[^"]+"[^{]*"workflow"|workflow[[:space:]]+"[^"]+"' \
      | sed -E 's/.*"([^"]+)".*/\1/' \
      | grep -v '^$' \
      | sort | uniq -c | sort -rn | head -5 \
      | awk 'BEGIN{printf "["} { if(NR>1) printf ","; n=$1; $1=""; sub(/^ /,""); gsub(/"/,"\\\""); printf "{\"workflow\":\"%s\",\"errors\":%d}", $0, n } END{printf "]"}' \
      2>/dev/null || echo "[]")
    echo "$BREAKDOWN_JSON" | jq -e . >/dev/null 2>&1 || BREAKDOWN_JSON="[]"
  fi
fi

if [ "$ERROR_COUNT" -gt 50 ]; then
  SAMPLE=$(remote 'docker logs n8n --since 24h 2>&1 | grep -iE "error|failed|timeout" | tail -3 | tr "\n" ";" | head -c 400')
  jq -c -n --arg src "n8n-self-health" --argjson count "$ERROR_COUNT" --arg sample "$SAMPLE" --argjson breakdown "$BREAKDOWN_JSON" \
    '{source:$src, severity:"HIGH", title:"n8n: \($count | tostring) errores en logs 24h", description:"Muchos errores acumulados. Top: \($breakdown | tostring). Sample: \($sample)", metadata:{count:$count, sample:$sample, breakdown:$breakdown}}'
elif [ "$ERROR_COUNT" -gt 10 ]; then
  jq -c -n --arg src "n8n-self-health" --argjson count "$ERROR_COUNT" --argjson breakdown "$BREAKDOWN_JSON" \
    '{source:$src, severity:"MEDIUM", title:"n8n: \($count | tostring) errores en logs 24h", description:"Nivel moderado. Top workflows: \($breakdown | tostring)", metadata:{count:$count, breakdown:$breakdown}}'
elif [ "$ERROR_COUNT" -gt 0 ]; then
  jq -c -n --arg src "n8n-self-health" --argjson count "$ERROR_COUNT" --argjson breakdown "$BREAKDOWN_JSON" \
    '{source:$src, severity:"LOW", title:"n8n: \($count | tostring) errores en logs 24h", description:"Nivel bajo, probablemente transitorios. Top: \($breakdown | tostring)", metadata:{count:$count, breakdown:$breakdown}}'
fi

# --- 4. Uptime container ---
UPTIME=$(remote 'docker inspect n8n --format "{{.State.StartedAt}}" 2>/dev/null || echo ""')
if [ -n "$UPTIME" ]; then
  # Si se reinició hace <1h → podría indicar crash loop
  NOW_EPOCH=$(date -u +%s)
  # GNU date (Linux) usa -d; BSD date (macOS) usa -j -f. Probar ambos para portabilidad
  START_EPOCH=$(date -u -d "$UPTIME" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "$UPTIME" | cut -d'.' -f1)" +%s 2>/dev/null || echo 0)
  AGE_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))

  if [ "$AGE_MIN" -lt 60 ] && [ "$AGE_MIN" -gt 0 ]; then
    jq -c -n --arg src "n8n-self-health" --argjson age "$AGE_MIN" --arg started "$UPTIME" \
      '{source:$src, severity:"MEDIUM", title:"n8n container started <1h ago", description:"Reinicio reciente (\($age | tostring) min). Verificar si fue manual o crash.", metadata:{uptime_min:$age, started_at:$started}}'
  fi
fi

# Si todo OK y ERROR_COUNT == 0 → INFO (precedencia con paréntesis)
if [ "$ERROR_COUNT" = "0" ] && { [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "404" ]; }; then
  jq -c -n --arg src "n8n-self-health" --arg state "$CONTAINER_STATE" --arg code "$HTTP_CODE" \
    '{source:$src, severity:"INFO", title:"n8n healthy", description:"Container: \($state), HTTP: \($code), 0 errores 24h", metadata:{state:$state, http_code:$code}}'
fi
