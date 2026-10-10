#!/usr/bin/env bash
# Despliega Guardia N1: empaqueta la Lambda, la sube a S3 y crea el stack de CloudFormation.
# Uso:  ./deploy.sh            (opcional: EMAIL=tu@correo.com ./deploy.sh)
set -euo pipefail
cd "$(dirname "$0")"
source ./_comun.sh

echo "==> Cuenta y region"
aws sts get-caller-identity --query '[Account,Arn]' --output text
echo "    Region: $AWS_REGION   Stack: $STACK"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '\r')

# Bucket de despliegue: se crea una vez y se recuerda en .deploy-state (destroy.sh lo borra).
BUCKET=""
if [ -f "$STATE_FILE" ]; then source "$STATE_FILE"; fi
if [ -z "${BUCKET:-}" ]; then
  BUCKET="${PROJECT}-deploy-${ACCOUNT_ID}-$(date +%s)"
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  echo "BUCKET=\"$BUCKET\"" > "$STATE_FILE"
  echo "==> Bucket creado: $BUCKET"
else
  echo "==> Bucket reutilizado: $BUCKET"
fi

echo "==> Empaquetando lambda_function.py"
rm -f oncall.zip
if command -v zip >/dev/null 2>&1; then
  zip -q oncall.zip lambda_function.py
else
  "$PY" -c "import zipfile; z=zipfile.ZipFile('oncall.zip','w',zipfile.ZIP_DEFLATED); z.write('lambda_function.py'); z.close()"
fi
# Clave versionada por hash: si el codigo cambia, CloudFormation actualiza la Lambda.
HASH=$("$PY" -c "import hashlib;print(hashlib.sha1(open('oncall.zip','rb').read()).hexdigest()[:10])" | tr -d '\r')
KEY="oncall-${HASH}.zip"
aws s3 cp oncall.zip "s3://${BUCKET}/${KEY}" --quiet

echo "==> Desplegando CloudFormation (2-3 min la primera vez)"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName="$PROJECT" DeployBucketName="$BUCKET" OnCallS3Key="$KEY" \
    NotificationEmail="${EMAIL:-}" \
  --no-fail-on-empty-changeset

aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table

echo ""
echo "QUE MIRAR AHORA:"
echo "  1. Estado de la alarma (debe decir OK o INSUFFICIENT_DATA):"
echo "     aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].StateValue' --output text"
echo "  2. En otra terminal, deja corriendo los logs del ingeniero de guardia:"
echo "     aws logs tail /aws/lambda/$ONCALL --follow --format short"
echo "  3. Cuando quieras romper produccion: ./provocar_fallo.sh"
