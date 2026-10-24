#!/usr/bin/env bash
# Ruta ALTERNATIVA: despliega Guardia N1 con CloudFormation (la principal es ./deploy.sh, con
# Terraform). Empaqueta la Lambda, la sube a S3 y crea el stack. Sin consola web: solo terminal.
# Uso:  ./deploy-cloudformation.sh            (opcional: EMAIL=tu@correo.com ./deploy-cloudformation.sh)
# El modelo sale de template.yaml (Claude Sonnet 4.6 por el perfil us.). Para usar otro se
# pasan los DOS parametros, el perfil y su modelo base, con este formato:
#   MODEL_ID=us.anthropic.claude-sonnet-4-6 FOUNDATION_MODEL_ID=anthropic.claude-sonnet-4-6 ./deploy-cloudformation.sh
# Se borra con ./destroy-cloudformation.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./_comun.sh

comprobar_identidad || exit 1
echo "    Stack: $STACK"
# Las dos rutas de IaC crean recursos con los mismos nombres: no pueden convivir.
N_TF=$(recursos_en_estado)
if [ "$N_TF" != "0" ]; then
  echo "ERROR: $TFSTATE tiene $N_TF recursos: la demo ya esta desplegada con Terraform." >&2
  echo "QUE MIRAR AHORA:"
  echo "  - Las dos rutas usan los mismos nombres. Borra esa con ./destroy.sh y repite, o sigue con ella."
  exit 1
fi

# Modelo: por defecto, los de template.yaml. Se pasan siempre los dos al stack.
default_de() {
  aws cloudformation get-template-summary --template-body file://template.yaml \
    --query "Parameters[?ParameterKey=='$1'].DefaultValue" --output text | tr -d '\r'
}
MODEL_ID="${MODEL_ID:-$(default_de ModelId)}"
FOUNDATION_MODEL_ID="${FOUNDATION_MODEL_ID:-$(default_de FoundationModelId)}"

# Antes de crear nada: el perfil existe en esta region y solo enruta a regiones que la politica
# IAM autoriza (InvocarModeloBaseViaPerfil en template.yaml), y la cuenta puede usar el modelo.
comprobar_perfil "$MODEL_ID" "$FOUNDATION_MODEL_ID" || exit 1
comprobar_acceso_modelo "$MODEL_ID" "$FOUNDATION_MODEL_ID" || exit 1

# Bucket de despliegue: se crea una vez y se recuerda en .deploy-state (destroy-cloudformation.sh lo borra).
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
# restaurar.sh y aprobar.sh leen la version estable de este archivo: sobrevive a un reinicio de CloudShell.
aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='StableVersion'].OutputValue" --output text \
  | tr -d '\r' > "$VERSION_FILE"

echo ""
echo "QUE MIRAR AHORA:"
echo "  1. Estado de la alarma (debe decir OK o INSUFFICIENT_DATA):"
echo "     aws cloudwatch describe-alarms --alarm-names $ALARMA --query 'MetricAlarms[0].StateValue' --output text"
echo "  2. En una segunda columna de CloudShell, deja corriendo la terminal del ingeniero de guardia:"
echo "     ./logs.sh"
echo "  3. Cuando quieras romper produccion: ./provocar_fallo.sh, o un bug de codigo: ./provocar_fallo.sh codigo"
echo "     (luego ./ver_diagnostico.sh y ./aprobar.sh)"
echo "  4. Al terminar, borra todo: ./destroy-cloudformation.sh"
