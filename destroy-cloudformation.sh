#!/usr/bin/env bash
# Ruta ALTERNATIVA: borra TODO lo que creo ./deploy-cloudformation.sh (stack, bucket de despliegue y
# estado local) y comprueba en la cuenta que no quedo nada.
# Si desplegaste con Terraform (./deploy.sh), el que borra es ./destroy.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
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
N_TF=$(recursos_en_estado)
if [ "$N_TF" != "0" ]; then
  echo ""
  echo "OJO: $TFSTATE tiene $N_TF recursos creados con Terraform (./deploy.sh)."
  echo "     Este script no los borra. Borralos con: ./destroy.sh"
  echo "     (funciona aunque CloudShell se haya reiniciado: reinstala Terraform y hace el init)"
  exit 1
fi
rm -f "$VERSION_FILE" .ultimo-incidente

echo ""
verificar_limpieza
LIMPIO=$?
echo ""
echo "QUE MIRAR AHORA:"
if [ "$LIMPIO" -eq 0 ]; then
  echo "  - Nada que hacer: la cuenta quedo sin recursos de la demo. Puedes cerrar CloudShell."
else
  echo "  - Arriba, lo que QUEDA. Si es de Terraform, borralo con ./destroy.sh; si no, desde la consola."
  echo "    Repite ./destroy-cloudformation.sh en 1 min: CloudFormation a veces tarda en soltar un recurso."
  exit 1
fi
