#!/usr/bin/env bash
# Vuelve al estado sano: alias live -> v1, $LATEST con DB_HOST=localhost y alarma en OK.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
# La version estable sale del stack: Lambda no reinicia la numeracion al recrear la funcion.
ESTABLE=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='StableVersion'].OutputValue" --output text | tr -d '\r')
aws lambda update-alias --function-name "$APP" --name live --function-version "$ESTABLE" >/dev/null && echo "live -> v$ESTABLE"
aws lambda update-function-configuration --function-name "$APP" \
  --environment "Variables={DB_HOST=localhost,DB_PORT=5432}" --query LastUpdateStatus --output text >/dev/null
aws lambda wait function-updated --function-name "$APP"
aws cloudwatch set-alarm-state --alarm-name "$ALARMA" --state-value OK --state-reason "Restaurado tras la demo"
R=$(aws lambda invoke --function-name "${APP}:live" --payload '{}' --cli-binary-format raw-in-base64-out \
     --query FunctionError --output text /dev/null 2>/dev/null | tr -d '\r')
if [ "$R" = "None" ]; then echo "Prueba de humo en live: OK"; else echo "Prueba de humo en live: FALLA ($R)"; fi
echo ""
echo "QUE MIRAR AHORA:"
echo "  - live apunta a la version estable y responde OK. Puedes repetir con ./provocar_fallo.sh"
