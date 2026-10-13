#!/usr/bin/env bash
# Borra TODA la demo en un solo paso (ruta Terraform, la de ./deploy.sh) y comprueba en la
# cuenta que no quedo nada. Funciona aunque CloudShell se haya reiniciado: reinstala Terraform,
# rehace el init y usa lo que vive en $HOME, el estado (terraform/terraform.tfstate) y las
# opciones del despliegue (terraform/deploy.auto.tfvars). No hace falta repetir WEB=... ni EMAIL=...
# Uso:  ./destroy.sh      (~3,5 min con la consola web: CloudFront deshabilita la distribucion antes
#                          de borrarla; ~15 s sin ella)
# Si desplegaste con CloudFormation (./deploy-cloudformation.sh), el que borra es ./destroy-cloudformation.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./_comun.sh
SECONDS=0

# La demo vive en la region donde se desplego, aunque esta terminal apunte a otra.
R_DEMO=$(previo region)
if [ -n "$R_DEMO" ] && [ "$R_DEMO" != "$AWS_REGION" ]; then
  echo "AVISO: la demo se desplego en $R_DEMO y esta terminal apunta a $AWS_REGION: borro en $R_DEMO."
  export AWS_REGION="$R_DEMO" AWS_DEFAULT_REGION="$R_DEMO"
fi
comprobar_identidad || exit 1

N_TF=$(recursos_en_estado)
BORRADO=1
STACK_VIVO=0
if [ "$N_TF" = "0" ]; then
  echo "==> $TFSTATE no tiene recursos: nada que borrar con Terraform."
  if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
    STACK_VIVO=1
    echo "    Pero existe el stack $STACK: la demo se desplego con CloudFormation."
    echo "    Borrala con: ./destroy-cloudformation.sh"
  fi
else
  echo "==> El estado de Terraform tiene $N_TF recursos: los borro todos"
  if ! preparar_terraform; then
    BORRADO=0
  else
    mkdir -p salidas
    LOG="salidas/terraform-destroy-$(date +%Y%m%d-%H%M%S).log"
    echo "==> terraform destroy (detalle completo en $LOG)"
    if ! terraform_resumido "$LOG" destroy -auto-approve; then
      BORRADO=0
      echo "ERROR: terraform destroy no termino. Arriba el error; el detalle esta en $LOG." >&2
    fi
  fi
fi
# Con el estado vacio ya no hacen falta las opciones del despliegue: el siguiente ./deploy.sh
# arranca con los valores por defecto. Si la demo vive en CloudFormation, sus archivos se quedan.
if [ "$STACK_VIVO" -eq 0 ] && [ "$(recursos_en_estado)" = "0" ]; then
  rm -f "$TFVARS" "$VERSION_FILE" .ultimo-incidente
fi

echo ""
verificar_limpieza
LIMPIO=$?
echo ""
printf 'Tiempo total: %d min %02d s\n' $((SECONDS / 60)) $((SECONDS % 60))
echo ""
echo "QUE MIRAR AHORA:"
if [ "$LIMPIO" -eq 0 ] && [ "$BORRADO" -eq 1 ]; then
  echo "  - Nada: la cuenta quedo sin recursos de la demo y no genera costos. Puedes cerrar CloudShell."
  echo "  - Para volver a montarla: ./deploy.sh"
  exit 0
fi
if [ "$STACK_VIVO" -eq 1 ]; then
  echo "  - Lo que queda es la demo de CloudFormation (stack $STACK): borrala con ./destroy-cloudformation.sh"
  exit 1
fi
echo "  - Arriba, lo que QUEDA o el error. Repite ./destroy.sh: Terraform retoma donde quedo."
echo "  - Si borraste $TFSTATE, Terraform ya no sabe que creo: borra lo que queda desde la consola."
exit 1
