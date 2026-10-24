#!/usr/bin/env bash
# Simula un MAL DESPLIEGUE real, de dos tipos:
#   ./provocar_fallo.sh          de CONFIGURACION: una version nueva de app-pagos con un DB_HOST que
#                                no existe. El codigo es el mismo de la version estable.
#   ./provocar_fallo.sh codigo   de CODIGO: una version nueva con un bug (fallos/app_pagos_con_bug.py:
#                                una comision que lee event["monto"], que los clientes no mandan).
#                                La configuracion es la misma de la version estable.
# En los dos, mueve el alias "live" a la version nueva y genera trafico. Los errores son reales.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
TIPO="${1:-configuracion}"
case "$TIPO" in
  configuracion|config) TIPO="configuracion" ;;
  codigo) ;;
  *) echo "Uso: ./provocar_fallo.sh [codigo]   (sin argumento, el fallo es de configuracion)"; exit 1 ;;
esac
HOST_MALO="${HOST_MALO:-db-pagos.prod.internal}"
PETICIONES="${PETICIONES:-12}"

# Se rompe sobre una base sana: si un fallo anterior no se restauro, la version nueva arrastraria
# los dos problemas y el diagnostico ya no seria el de este fallo.
if buscar_version_estable && ! comparar_con_version "$ESTABLE"; then
  echo "El \$LATEST de $APP no esta como la version estable v$ESTABLE (cambia: $DIF)."
  echo "Un fallo anterior quedo sin restaurar."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Ejecuta ./restaurar.sh y vuelve a intentarlo."
  exit 1
fi

echo $(( $(date +%s) * 1000 )) > .ultimo-incidente   # ver_diagnostico.sh mira desde aqui
echo "==> Version en produccion ANTES: v$(aws lambda get-alias --function-name "$APP" --name live --query FunctionVersion --output text | tr -d '\r')"

if [ "$TIPO" = "codigo" ]; then
  if [ -z "$PY" ]; then echo "ERROR: hace falta python3 para empaquetar el codigo." >&2; exit 1; fi
  ZIP="$(mktemp -d)/app-pagos-con-bug.zip"
  # Se empaqueta como index.py, igual que Terraform y CloudFormation, con permisos de lectura (0644).
  "$PY" - "$ZIP" <<'PYEOF'
import sys, zipfile
info = zipfile.ZipInfo("index.py", date_time=(2026, 10, 24, 0, 0, 0))
info.external_attr = 0o644 << 16
info.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile(sys.argv[1], "w") as z, open("fallos/app_pagos_con_bug.py", "rb") as f:
    z.writestr(info, f.read())
PYEOF
  echo "==> Desplegando codigo nuevo: fallos/app_pagos_con_bug.py (comision del 1,5 %)"
  aws lambda update-function-code --function-name "$APP" --zip-file "fileb://$ZIP" \
    --query LastUpdateStatus --output text
  DESCRIPCION="release viernes 6pm (comision del 1,5 %)"
else
  echo "==> Desplegando configuracion nueva: DB_HOST=$HOST_MALO"
  aws lambda update-function-configuration --function-name "$APP" \
    --environment "Variables={DB_HOST=$HOST_MALO,DB_PORT=5432}" --query LastUpdateStatus --output text
  DESCRIPCION="release viernes 6pm (DB_HOST=$HOST_MALO)"
fi
aws lambda wait function-updated --function-name "$APP"
V=$(aws lambda publish-version --function-name "$APP" \
     --description "$DESCRIPCION" --query Version --output text | tr -d '\r')
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
echo "  - El error crudo, en los logs de la app (es lo que el N1 resume):"
echo "    aws logs tail /aws/lambda/$APP --since 5m"
echo "  - La alarma tarda 1-3 min en pasar a ALARM (la metrica de Lambda es por minuto):"
echo "    aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].[StateValue,StateReason]' --output text"
echo "  - En cuanto pase a ALARM, la columna de ./logs.sh mostrara el diagnostico (~15-25 s)."
echo "  - O espera y ejecuta: ./ver_diagnostico.sh  (y despues ./aprobar.sh para aprobar el rollback)"
