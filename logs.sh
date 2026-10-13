#!/usr/bin/env bash
# La terminal del ingeniero de guardia: los logs del N1 en vivo. Dejala corriendo en una segunda
# columna de CloudShell (Actions -> Tabs layout -> Split into columns). Ctrl+C para salir.
# Oculta las dos lineas JSON largas (CONTEXTO_JSON y DIAGNOSTICO_JSON); el diagnostico legible
# aparece igual, en el bloque "GUARDIA N1".
# Uso:  ./logs.sh                (empieza mostrando los ultimos 10 min)
#       HACE=1h ./logs.sh        (desde hace una hora; acepta s, m, h, d y w)
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./_comun.sh
LOG_GROUP="/aws/lambda/$ONCALL"

EXISTE=$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output text \
  --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" 2>/dev/null | tr -d '\r')
if [ "$EXISTE" != "$LOG_GROUP" ]; then
  echo "No encuentro el log group $LOG_GROUP en $AWS_REGION."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Despliega primero la demo: ./deploy.sh"
  echo "  - Si ya esta desplegada, esta terminal apunta a otra region: export AWS_REGION=us-east-1"
  exit 1
fi

echo "==> Terminal del ingeniero de guardia: $LOG_GROUP ($AWS_REGION). Ctrl+C para salir."
echo ""
echo "QUE MIRAR AHORA:"
echo "  - Cuando la alarma pase a ALARM aparecen, en unos 10 s: '[guardia] Alarma ... -> ALARM',"
echo "    el contexto recogido, 'Bedrock respondio en ...' y el bloque GUARDIA N1 con la severidad,"
echo "    la causa raiz y el comando propuesto. Ese comando NO se ejecuta: lo apruebas con ./aprobar.sh"
echo "  - CloudShell cierra la sesion tras 20-30 min sin teclado, aunque esto siga corriendo."
echo "    Si se cerro: Actions -> Restart, entra a la carpeta y ./logs.sh otra vez."
echo "----------------------------------------------------------------------"
exec aws logs tail "$LOG_GROUP" --follow --format short --since "${HACE:-10m}" \
  --filter-pattern '-"CONTEXTO_JSON" -"DIAGNOSTICO_JSON"'
