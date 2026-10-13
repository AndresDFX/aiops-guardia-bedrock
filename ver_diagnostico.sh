#!/usr/bin/env bash
# Busca el ultimo diagnostico en los logs del ingeniero de guardia y lo muestra legible.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
# El ultimo diagnostico desde el ultimo incidente provocado (o de los ultimos MIN minutos):
# leer_ultimo_diagnostico, en _comun.sh, deja DIAG_JSON y DESDE. aprobar.sh usa la misma busqueda.
leer_ultimo_diagnostico
if [ -z "$DIAG_JSON" ]; then
  ESTADO=$(aws cloudwatch describe-alarms --alarm-names "$ALARMA" --query 'MetricAlarms[0].StateValue' --output text | tr -d '\r')
  echo "Aun no hay diagnostico de este incidente. Alarma: $ESTADO"
  # Si el ingeniero de guardia ya fallo (sin acceso al modelo, cuota en 0, throttling),
  # su log lo dice: no tiene sentido seguir esperando.
  FALLO=$(aws logs filter-log-events --log-group-name "/aws/lambda/$ONCALL" \
    --start-time "$DESDE" --filter-pattern '"[guardia] ERROR"' \
    --query 'events[].message' --output json 2>/dev/null \
    | "$PY" -c "import json,sys; m=json.load(sys.stdin) or ['']; print(m[-1].strip()[:400])" 2>/dev/null | tr -d '\r')
  if [ -n "$FALLO" ]; then
    echo "El ingeniero de guardia fallo al llamar a Bedrock:"
    echo "  $FALLO"
    echo "QUE MIRAR AHORA:"
    echo "  - AccessDeniedException ('not available for this account'): tu cuenta no puede usar ese modelo."
    echo "    ./deploy.sh revisa el acuerdo y la cuota del modelo al empezar; o despliega con otro modelo."
    echo "  - ThrottlingException: Lambda reintenta sola; repite ./ver_diagnostico.sh en 1 min."
    exit 1
  fi
  echo "QUE MIRAR AHORA:"
  echo "  - Si la alarma sigue en OK, espera 1 min y repite."
  echo "  - Si ya esta en ALARM, espera ~20 s: Bedrock esta pensando."
  exit 0
fi
JSON="$DIAG_JSON"
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
echo "  - Si estas de acuerdo, apruebalo: ./aprobar.sh  (valida el comando y te pide confirmacion)"
echo "  - Guardado en $F"
echo "  - Para volver al estado sano sin aprobar nada: ./restaurar.sh"
