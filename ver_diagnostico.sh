#!/usr/bin/env bash
# Busca el ultimo diagnostico en los logs del ingeniero de guardia y lo muestra legible.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
MIN="${MIN:-20}"
DESDE=$(( ( $(date +%s) - MIN*60 ) * 1000 ))
# Solo diagnosticos posteriores al ultimo incidente provocado: si repites la demo,
# no quieres que la pantalla muestre el diagnostico de la vez anterior.
if [ -f .ultimo-incidente ]; then DESDE=$(cat .ultimo-incidente); fi
# --output json (no text): con text el CLI aplica el --query pagina a pagina y la ultima,
# vacia, anade un "None" que rompe el JSON. En json primero junta todas las paginas.
LINEA=$(aws logs filter-log-events --log-group-name "/aws/lambda/$ONCALL" \
  --start-time "$DESDE" --filter-pattern '"DIAGNOSTICO_JSON"' \
  --query 'events[].message' --output json 2>/dev/null \
  | "$PY" -c "import json,sys; m=json.load(sys.stdin) or ['']; print(m[-1].strip())" 2>/dev/null | tr -d '\r')
if [ -z "$LINEA" ]; then
  ESTADO=$(aws cloudwatch describe-alarms --alarm-names "$ALARMA" --query 'MetricAlarms[0].StateValue' --output text | tr -d '\r')
  echo "Aun no hay diagnostico de este incidente. Alarma: $ESTADO"
  echo "QUE MIRAR AHORA:"
  echo "  - Si la alarma sigue en OK, espera 1 min y repite."
  echo "  - Si ya esta en ALARM, espera ~20 s: Bedrock esta pensando."
  exit 0
fi
JSON="${LINEA#*DIAGNOSTICO_JSON: }"
mkdir -p salidas
F="salidas/diagnostico-$(date +%Y%m%d-%H%M%S).json"
if [ -n "$PY" ]; then
  printf '%s' "$JSON" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d,indent=2,ensure_ascii=False))" > "$F"
else
  printf '%s' "$JSON" > "$F"
fi
cat "$F"
echo ""
echo "QUE MIRAR AHORA:"
echo "  - severidad, causa_raiz y comando_remediacion. Ese comando NO se ejecuto: lo apruebas tu."
echo "  - Guardado en $F"
echo "  - Para volver al estado sano: ./restaurar.sh"
