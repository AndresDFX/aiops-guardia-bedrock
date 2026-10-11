#!/usr/bin/env bash
# Vuelve al estado sano: alias live a la version estable, $LATEST con DB_HOST=localhost y alarma en OK.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
# La version estable sale de la IaC: Lambda no reinicia la numeracion al recrear la funcion.
# Se busca en este orden:
#   1. .version-estable, que escriben deploy.sh y terraform apply. Vive en $HOME, asi que
#      sobrevive a un reinicio de CloudShell aunque Terraform ya no este instalado.
#   2. El Output StableVersion del stack de CloudFormation.
#   3. terraform output stable_version (pide Terraform instalado y el init hecho).
#   4. El mismo output, leido del estado de Terraform con python.
#   5. La configuracion desplegada del ingeniero de guardia: el despliegue le pasa la estable
#      en la variable STABLE_VERSIONS. Sirve en una sesion sin el estado ni el archivo (por
#      ejemplo, si desplegaste desde tu portatil y restauras desde CloudShell).
es_numero() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ESTABLE=""; FUENTE=""
if [ -f "$VERSION_FILE" ]; then
  ESTABLE=$(tr -d ' \r\n' < "$VERSION_FILE"); FUENTE="$VERSION_FILE"
fi
if ! es_numero "$ESTABLE"; then
  ESTABLE=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='StableVersion'].OutputValue" --output text 2>/dev/null | tr -d '\r')
  FUENTE="Output StableVersion del stack"
fi
TFSTATE="terraform/terraform.tfstate"
if ! es_numero "$ESTABLE" && [ -d terraform ] && command -v terraform >/dev/null 2>&1; then
  ESTABLE=$(terraform -chdir=terraform output -raw stable_version 2>/dev/null | tr -d '\r')
  FUENTE="terraform output"
fi
if ! es_numero "$ESTABLE" && [ -f "$TFSTATE" ] && [ -n "$PY" ]; then
  ESTABLE=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['outputs']['stable_version']['value'])" \
    "$TFSTATE" 2>/dev/null | tr -d '\r')
  FUENTE="$TFSTATE"
fi
if ! es_numero "$ESTABLE" && [ -n "$PY" ]; then
  ESTABLE=$(aws lambda get-function-configuration --function-name "$ONCALL" \
    --query 'Environment.Variables.STABLE_VERSIONS' --output text 2>/dev/null | tr -d '\r' \
    | "$PY" -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ''))" "$APP" 2>/dev/null | tr -d '\r')
  FUENTE="la variable STABLE_VERSIONS de la Lambda $ONCALL"
fi
if ! es_numero "$ESTABLE"; then
  echo "No encontre la version estable: no hay $VERSION_FILE, ni stack $STACK, ni output stable_version de Terraform,"
  echo "ni la variable STABLE_VERSIONS en la Lambda $ONCALL (con la entrada de $APP)."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Lista las versiones y elige la buena:"
  echo "    aws lambda list-versions-by-function --function-name $APP --query 'Versions[].[Version,Description]' --output table"
  exit 1
fi
if ! aws lambda update-alias --function-name "$APP" --name live --function-version "$ESTABLE" >/dev/null; then
  echo "No pude mover live a v$ESTABLE (leida de $FUENTE). Si ya borraste la demo, borra $VERSION_FILE."
  exit 1
fi
echo "live -> v$ESTABLE  (version estable, leida de $FUENTE)"
aws lambda update-function-configuration --function-name "$APP" \
  --environment "Variables={DB_HOST=localhost,DB_PORT=5432}" --query LastUpdateStatus --output text >/dev/null
aws lambda wait function-updated --function-name "$APP"
R=$(aws lambda invoke --function-name "${APP}:live" --payload '{}' --cli-binary-format raw-in-base64-out \
     --query FunctionError --output text /dev/null 2>/dev/null | tr -d '\r')
if [ "$R" = "None" ]; then echo "Prueba de humo en live: OK"; else echo "Prueba de humo en live: FALLA ($R)"; fi
# No se fuerza la alarma a OK: si el minuto con errores sigue en su ventana de evaluacion,
# rebota a ALARM y llega otro diagnostico (medido el 10-oct). Vuelve sola a OK en cuanto
# evalua un minuto sin errores: se espera eso.
printf "Esperando a que la alarma vuelva sola a OK (max. 3 min) "
ESTADO=""
for _ in $(seq 1 36); do
  ESTADO=$(aws cloudwatch describe-alarms --alarm-names "$ALARMA" --query 'MetricAlarms[0].StateValue' --output text | tr -d '\r')
  [ "$ESTADO" != "ALARM" ] && break
  printf '.'; sleep 5
done
echo " $ESTADO"
echo ""
echo "QUE MIRAR AHORA:"
if [ "$ESTADO" = "ALARM" ]; then
  echo "  - La alarma sigue en ALARM tras 3 min: live todavia falla o hay errores de otra version."
  echo "    aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].[StateValue,StateReason]' --output text"
else
  echo "  - live apunta a la version estable, responde OK y la alarma esta en $ESTADO."
  echo "    Puedes repetir con ./provocar_fallo.sh o probar la falsa alarma con ./simular_alarma.sh"
fi
