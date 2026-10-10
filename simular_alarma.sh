#!/usr/bin/env bash
# Prueba de honestidad (y plan B rapido): fuerza la alarma a ALARM SIN errores reales.
# El diagnostico deberia reconocer que las metricas NO respaldan la alarma.
set -uo pipefail
cd "$(dirname "$0")"
source ./_comun.sh
echo $(( $(date +%s) * 1000 )) > .ultimo-incidente   # ver_diagnostico.sh mira desde aqui
aws cloudwatch set-alarm-state --alarm-name "$ALARMA" --state-value ALARM \
  --state-reason "Prueba manual: alarma forzada con set-alarm-state"
echo "Alarma $ALARMA forzada a ALARM."
echo ""
echo "QUE MIRAR AHORA:"
echo "  - En ~20 s: ./ver_diagnostico.sh  (sin errores reales, espera posible_falsa_alarma=true)"
echo "  - La alarma vuelve sola a OK en la siguiente evaluacion (~1 min)."
