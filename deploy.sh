#!/usr/bin/env bash
# Despliega Guardia N1 con CloudFormation (la ruta principal es terraform/): empaqueta la
# Lambda, la sube a S3 y crea el stack.
# Uso:  ./deploy.sh            (opcional: EMAIL=tu@correo.com ./deploy.sh)
# El modelo sale de template.yaml (Claude Sonnet 4.6 por el perfil us.). Para usar otro se
# pasan los DOS parametros, el perfil y su modelo base, con este formato:
#   MODEL_ID=us.anthropic.claude-sonnet-4-6 FOUNDATION_MODEL_ID=anthropic.claude-sonnet-4-6 ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./_comun.sh

echo "==> Cuenta y region"
aws sts get-caller-identity --query '[Account,Arn]' --output text
echo "    Region: $AWS_REGION   Stack: $STACK"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '\r')

# Modelo: por defecto, los de template.yaml. Se pasan siempre los dos al stack.
default_de() {
  aws cloudformation get-template-summary --template-body file://template.yaml \
    --query "Parameters[?ParameterKey=='$1'].DefaultValue" --output text | tr -d '\r'
}
MODEL_ID="${MODEL_ID:-$(default_de ModelId)}"
FOUNDATION_MODEL_ID="${FOUNDATION_MODEL_ID:-$(default_de FoundationModelId)}"

# Antes de crear nada: el perfil existe en esta region, usa ese modelo base y solo enruta a
# regiones que la politica IAM autoriza. Si no, la Lambda daria AccessDenied (a veces si y
# a veces no) en plena demo. Son las tres de InvocarModeloBaseViaPerfil en template.yaml.
REGIONES_IAM="us-east-1 us-east-2 us-west-2"
echo "==> Modelo: $MODEL_ID (modelo base $FOUNDATION_MODEL_ID)"
if ! ARNS=$(aws bedrock get-inference-profile --inference-profile-identifier "$MODEL_ID" \
      --query 'models[].modelArn' --output text 2>&1); then
  echo "ERROR: no pude leer el perfil $MODEL_ID en $AWS_REGION:" >&2
  echo "$ARNS" | sed '/^[[:space:]]*$/d; s/^/  /' >&2
  echo "  La demo esta probada en us-east-1: export AWS_REGION=us-east-1" >&2
  exit 1
fi
DESTINOS=""
for ARN in $(echo "$ARNS" | tr -d '\r'); do
  R=$(echo "$ARN" | cut -d: -f4)
  if [ "${ARN##*/}" != "$FOUNDATION_MODEL_ID" ]; then
    echo "ERROR: el perfil $MODEL_ID no usa el modelo base $FOUNDATION_MODEL_ID ($ARN)." >&2
    exit 1
  fi
  case " $REGIONES_IAM " in
    *" $R "*) DESTINOS="$DESTINOS $R" ;;
    *) echo "ERROR: desde $AWS_REGION el perfil enruta tambien a ${R:-una region global}, que la politica IAM no autoriza." >&2
       echo "  Usa us-east-1 (export AWS_REGION=us-east-1) o agrega esa region en template.yaml." >&2
       exit 1 ;;
  esac
done
echo "    El perfil enruta a:$DESTINOS. La politica IAM autoriza esas regiones."

# Bucket de despliegue: se crea una vez y se recuerda en .deploy-state (destroy.sh lo borra).
BUCKET=""
if [ -f "$STATE_FILE" ]; then source "$STATE_FILE"; fi
if [ -n "${BUCKET:-}" ] && ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "==> El bucket de $STATE_FILE ($BUCKET) ya no existe: creo otro"
  BUCKET=""
fi
if [ -z "${BUCKET:-}" ]; then
  BUCKET="${PROJECT}-deploy-${ACCOUNT_ID}-$(date +%s)"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    # Fuera de us-east-1, S3 exige la region en LocationConstraint.
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  fi
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
# --only-show-errors y no --quiet: si la subida falla, el error se ve.
aws s3 cp oncall.zip "s3://${BUCKET}/${KEY}" --only-show-errors

echo "==> Desplegando CloudFormation (2-3 min la primera vez)"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ProjectName="$PROJECT" DeployBucketName="$BUCKET" OnCallS3Key="$KEY" \
    NotificationEmail="${EMAIL:-}" ModelId="$MODEL_ID" FoundationModelId="$FOUNDATION_MODEL_ID" \
  --no-fail-on-empty-changeset

aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
# restaurar.sh lee la version estable de este archivo: sobrevive a un reinicio de CloudShell.
aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='StableVersion'].OutputValue" --output text \
  | tr -d '\r' > "$VERSION_FILE"

echo ""
echo "QUE MIRAR AHORA:"
echo "  1. Estado de la alarma (debe decir OK o INSUFFICIENT_DATA):"
echo "     aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].StateValue' --output text"
echo "  2. En otra terminal, deja corriendo los logs del ingeniero de guardia"
echo "     (sin las dos lineas JSON largas, que guardan el contexto y el diagnostico):"
echo "     aws logs tail /aws/lambda/$ONCALL --follow --format short --filter-pattern '-\"CONTEXTO_JSON\" -\"DIAGNOSTICO_JSON\"'"
echo "  3. Cuando quieras romper produccion: ./provocar_fallo.sh"
