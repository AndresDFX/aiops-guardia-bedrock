#!/usr/bin/env bash
# Simula un MAL DESPLIEGUE real: publica una version nueva de app-pagos con un DB_HOST que
# no existe, mueve el alias "live" a esa version y genera trafico. Los errores son reales.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
HOST_MALO="${HOST_MALO:-db-pagos.prod.internal}"
PETICIONES="${PETICIONES:-12}"

echo $(( $(date +%s) * 1000 )) > .ultimo-incidente   # ver_diagnostico.sh mira desde aqui
echo "==> Version en produccion ANTES: v$(aws lambda get-alias --function-name "$APP" --name live --query FunctionVersion --output text | tr -d '\r')"

echo "==> Desplegando configuracion nueva: DB_HOST=$HOST_MALO"
aws lambda update-function-configuration --function-name "$APP" \
  --environment "Variables={DB_HOST=$HOST_MALO,DB_PORT=5432}" --query LastUpdateStatus --output text
aws lambda wait function-updated --function-name "$APP"
V=$(aws lambda publish-version --function-name "$APP" \
     --description "release viernes 6pm (DB_HOST=$HOST_MALO)" --query Version --output text | tr -d '\r')
aws lambda update-alias --function-name "$APP" --name live --function-version "$V" >/dev/null
echo "    live -> v$V"

echo "==> Trafico de clientes: $PETICIONES peticiones a ${APP}:live  (. = OK, x = error)"
OK=0; FAIL=0
for i in $(seq 1 "$PETICIONES"); do
  R=$(aws lambda invoke --function-name "${APP}:live" --payload '{}' \
       --cli-binary-format raw-in-base64-out --query FunctionError --output text /dev/null 2>/dev/null | tr -d '\r')
  if [ "$R" = "Unhandled" ]; then FAIL=$((FAIL+1)); printf 'x'; else OK=$((OK+1)); printf '.'; fi
done
echo ""
echo "    Resultado: $OK OK, $FAIL con error"

echo ""
echo "QUE MIRAR AHORA:"
echo "  - La alarma tarda 1-3 min en pasar a ALARM (la metrica de Lambda es por minuto):"
echo "    aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].[StateValue,StateReason]' --output text"
echo "  - En cuanto pase a ALARM, la columna de ./logs.sh mostrara el diagnostico (~15-25 s)."
echo "  - O espera y ejecuta: ./ver_diagnostico.sh  (y despues ./aprobar.sh para aprobar el rollback)"
