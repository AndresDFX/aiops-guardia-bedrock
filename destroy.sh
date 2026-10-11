#!/usr/bin/env bash
# Borra TODO lo que creo deploy.sh (ruta CloudFormation): stack, bucket de despliegue y estado local.
# Si desplegaste con Terraform, el que borra es: terraform -chdir=terraform destroy
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh

if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  echo "==> Borrando stack $STACK (Lambdas, versiones, alarma, regla, topic, roles y log groups)"
  aws cloudformation delete-stack --stack-name "$STACK"
  if aws cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    echo "    Stack borrado."
  else
    echo "    ERROR: el stack no termino de borrarse. Mira el motivo con:"
    echo "    aws cloudformation describe-stack-events --stack-name $STACK --max-items 5 --query 'StackEvents[].[LogicalResourceId,ResourceStatus,ResourceStatusReason]' --output table"
  fi
else
  echo "==> No hay stack $STACK: nada que borrar con CloudFormation."
fi

BUCKET=""
if [ -f "$STATE_FILE" ]; then source "$STATE_FILE"; fi
if [ -n "${BUCKET:-}" ]; then
  if aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1; then
    echo "==> Bucket $BUCKET borrado."
  else
    echo "==> El bucket $BUCKET ya no existia."
  fi
fi
rm -f "$STATE_FILE" oncall.zip

# Lo que creo Terraform no lo toca este script. Si hay recursos en el estado, se dice claro.
TF_RECURSOS=0
if [ -f terraform/terraform.tfstate ] && [ -n "$PY" ]; then
  TF_RECURSOS=$("$PY" -c "import json,sys; r=json.load(open(sys.argv[1])).get('resources',[]); print(sum(1 for x in r if x.get('mode')=='managed'))" \
    terraform/terraform.tfstate 2>/dev/null | tr -d '\r')
fi
if [ "${TF_RECURSOS:-0}" -gt 0 ] 2>/dev/null; then
  echo ""
  echo "OJO: terraform/terraform.tfstate tiene $TF_RECURSOS recursos creados con Terraform."
  echo "     Este script no los borra. Borralos con: terraform -chdir=terraform destroy"
  echo "     (en una sesion nueva de CloudShell, primero reinstala Terraform y haz init)"
  exit 1
fi
rm -f "$VERSION_FILE"

echo ""
echo "QUE MIRAR AHORA (las tres consultas deben salir vacias):"
echo "  aws lambda list-functions --query 'Functions[?starts_with(FunctionName,\`$PROJECT-\`)].FunctionName' --output text"
echo "  aws cloudwatch describe-alarms --alarm-name-prefix $PROJECT- --query 'MetricAlarms[].AlarmName' --output text"
echo "  aws logs describe-log-groups --log-group-name-prefix /aws/lambda/$PROJECT- --query 'logGroups[].logGroupName' --output text"
