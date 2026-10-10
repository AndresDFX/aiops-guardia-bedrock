#!/usr/bin/env bash
# Borra TODO lo que creo la demo: stack, bucket de despliegue y estado local.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
echo "==> Borrando stack $STACK (Lambdas, versiones, alarma, regla, topic, roles y log groups)"
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" && echo "    Stack borrado."
BUCKET=""
if [ -f "$STATE_FILE" ]; then source "$STATE_FILE"; fi
if [ -n "${BUCKET:-}" ]; then
  aws s3 rb "s3://$BUCKET" --force >/dev/null && echo "==> Bucket $BUCKET borrado."
fi
rm -f "$STATE_FILE" oncall.zip
echo ""
echo "QUE MIRAR AHORA (las tres consultas deben salir vacias):"
echo "  aws lambda list-functions --query 'Functions[?starts_with(FunctionName,\`$PROJECT-\`)].FunctionName' --output text"
echo "  aws cloudwatch describe-alarms --alarm-name-prefix $PROJECT- --query 'MetricAlarms[].AlarmName' --output text"
echo "  aws logs describe-log-groups --log-group-name-prefix /aws/lambda/$PROJECT- --query 'logGroups[].logGroupName' --output text"
