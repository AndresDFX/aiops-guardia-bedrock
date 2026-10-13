#!/usr/bin/env bash
# Crea TODA la demo en un solo paso, con Terraform (la ruta principal). Se puede repetir: si ya
# esta desplegada no cambia nada y vuelve a imprimir la URL, el PIN y los siguientes pasos.
#   1. Comprueba la cuenta, la region y que el perfil del modelo exista en esa region.
#   2. Comprueba que la cuenta pueda usar el modelo. Si el acuerdo de Marketplace no esta
#      AVAILABLE, hace la primera invocacion con TU usuario (es la que lo activa) y espera.
#   3. Instala Terraform si falta (CloudShell lo borra al cerrar la sesion).
#   4. terraform init y apply, con la cache de providers en /tmp.
#   5. Imprime el resumen: consola web, PIN, version estable y que hacer despues.
# Uso:  ./deploy.sh
# Opciones (quedan en terraform/deploy.auto.tfvars: el siguiente deploy y el destroy las respetan):
#   EMAIL=tu@correo.com ./deploy.sh   el diagnostico llega tambien por correo (SNS)
#   WEB=false ./deploy.sh             sin consola web: 18 recursos y un destroy de ~15 s
#   OCULTAR_PIN=1 ./deploy.sh         no muestra el PIN (por si la pantalla esta proyectada)
#   Otro modelo: los DOS IDs, el perfil y su modelo base, con este formato:
#   MODEL_ID=us.anthropic.claude-sonnet-4-6 FOUNDATION_MODEL_ID=anthropic.claude-sonnet-4-6 ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
SECONDS=0

# Valores por defecto: los de terraform/variables.tf, para no repetirlos aqui.
default_tf() {
  sed -n "/^variable \"$1\"/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p" \
    terraform/variables.tf | sed -n '1p'
}
# Cada opcion: la variable si la pasaste; si no, la del despliegue anterior; si no, el valor por defecto.
WEB_VAL="${WEB-$(previo web_enabled)}"
WEB_VAL="${WEB_VAL:-true}"
EMAIL_VAL="${EMAIL-$(previo notification_email)}"
MODEL_VAL="${MODEL_ID-$(previo model_id)}"
MODEL_VAL="${MODEL_VAL:-$(default_tf model_id)}"
FM_VAL="${FOUNDATION_MODEL_ID-$(previo foundation_model_id)}"
FM_VAL="${FM_VAL:-$(default_tf foundation_model_id)}"
case "$WEB_VAL" in
  true|false) ;;
  *) echo "ERROR: WEB tiene que ser true o false (llego '$WEB_VAL')." >&2; exit 1 ;;
esac
case "$EMAIL_VAL" in
  "") ;;
  *[!A-Za-z0-9._%+@-]*|*@*@*) echo "ERROR: EMAIL no parece un correo: '$EMAIL_VAL'." >&2; exit 1 ;;
  ?*@?*.?*) ;;
  *) echo "ERROR: EMAIL no parece un correo: '$EMAIL_VAL'." >&2; exit 1 ;;
esac
for v in "$MODEL_VAL" "$FM_VAL"; do
  case "$v" in ''|*[!A-Za-z0-9._:-]*) echo "ERROR: ID de modelo no valido: '$v'." >&2; exit 1 ;; esac
done

# 1. Cuenta, region y perfil
comprobar_identidad || exit 1
R_PREVIA=$(previo region)
if [ -n "$R_PREVIA" ] && [ "$R_PREVIA" != "$AWS_REGION" ] && [ "$(recursos_en_estado)" != "0" ]; then
  echo "ERROR: la demo ya esta desplegada en $R_PREVIA y esta terminal apunta a $AWS_REGION." >&2
  echo "QUE MIRAR AHORA:"
  echo "  - export AWS_REGION=$R_PREVIA y repite ./deploy.sh (o borrala antes con ./destroy.sh)."
  exit 1
fi
# Las dos rutas de IaC crean recursos con los mismos nombres: no pueden convivir.
if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
  echo "ERROR: en esta cuenta ya hay una demo desplegada con CloudFormation (stack $STACK)." >&2
  echo "QUE MIRAR AHORA:"
  echo "  - Las dos rutas usan los mismos nombres. Borra esa con ./destroy-cloudformation.sh y repite"
  echo "    ./deploy.sh, o sigue la demo con ella: los demas scripts son los mismos."
  exit 1
fi
comprobar_perfil "$MODEL_VAL" "$FM_VAL" || exit 1

# 2. Acceso de la cuenta al modelo (acuerdo de Marketplace y cuota)
comprobar_acceso_modelo "$MODEL_VAL" "$FM_VAL" || exit 1

# 3. Terraform (se instala si falta) y init
preparar_terraform || exit 1

# 4. Apply. Las opciones van a un .auto.tfvars: Terraform lo lee solo en plan, apply y destroy.
cat > "$TFVARS" <<EOF
# Lo escribe ./deploy.sh con las opciones del despliegue. Terraform lo carga solo (*.auto.tfvars)
# en plan, apply y destroy: ./destroy.sh y un "terraform plan" a mano usan los mismos valores.
# Esta en .gitignore: puede llevar tu correo.
region              = "$AWS_REGION"
project_name        = "$PROJECT"
web_enabled         = $WEB_VAL
notification_email  = "$EMAIL_VAL"
model_id            = "$MODEL_VAL"
foundation_model_id = "$FM_VAL"
EOF
mkdir -p salidas
LOG="salidas/terraform-apply-$(date +%Y%m%d-%H%M%S).log"
echo "==> terraform apply (el plan completo queda en $LOG)"
if ! terraform_resumido "$LOG" apply -auto-approve; then
  echo "ERROR: terraform apply fallo. Arriba el error; el detalle completo esta en $LOG." >&2
  echo "QUE MIRAR AHORA:"
  echo "  - Corrige la causa y repite ./deploy.sh: Terraform retoma donde quedo."
  echo "  - Para borrar lo que alcanzo a crear: ./destroy.sh"
  exit 1
fi

# 5. Resumen
out() { terraform -chdir=terraform output -raw "$1" 2>/dev/null | tr -d '\r' || true; }
ESTABLE=$(out stable_version)
URL=$(out web_url)
# restaurar.sh y aprobar.sh leen la estable de aqui: sobrevive a un reinicio de CloudShell.
if es_numero "$ESTABLE"; then echo "$ESTABLE" > "$VERSION_FILE"; fi
ESTADO=$(aws cloudwatch describe-alarms --alarm-names "$ALARMA" \
  --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null | tr -d '\r' || true)
[ "$ESTADO" = "INSUFFICIENT_DATA" ] && ESTADO="INSUFFICIENT_DATA, pasa a OK en 1-2 min"

echo ""
echo "================================================================"
printf '  GUARDIA N1 LISTA en %s  (%d min %02d s)\n' "$AWS_REGION" $((SECONDS / 60)) $((SECONDS % 60))
echo "================================================================"
echo "  Servicio de pagos : $APP, alias live -> v$ESTABLE (la version estable)"
echo "  Alarma            : $ALARMA ($ESTADO)"
echo "  Ingeniero N1      : $ONCALL, con $MODEL_VAL y rol de solo lectura"
if [ "$WEB_VAL" = "true" ]; then
  HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL/" 2>/dev/null | tr -d '\r' || true)
  echo "  Consola web       : $URL"
  if [ "$HTTP" = "200" ]; then
    echo "                      ya responde."
  else
    echo "                      CloudFront tarda 1-2 min en publicarla: si no abre, espera y recarga."
  fi
  if [ -n "${OCULTAR_PIN:-}" ]; then
    echo "  PIN de la web     : ******** (oculto; lo da: terraform -chdir=terraform output -raw web_pin)"
  else
    echo "  PIN de la web     : $(out web_pin)   (si lo pierdes, ./deploy.sh lo vuelve a mostrar)"
  fi
else
  echo "  Consola web       : no (WEB=false). WEB=true ./deploy.sh la crea."
fi
if [ -n "$EMAIL_VAL" ]; then
  echo "  Correo            : $EMAIL_VAL (confirma la suscripcion en el correo de AWS Notifications)"
fi
echo ""
PASOS=$(out siguientes_pasos)
if [ -n "$PASOS" ]; then
  echo "$PASOS"
else
  echo "QUE MIRAR AHORA:"
  echo "  ./logs.sh en otra columna, ./provocar_fallo.sh, ./ver_diagnostico.sh, ./aprobar.sh y, al final, ./destroy.sh"
fi
