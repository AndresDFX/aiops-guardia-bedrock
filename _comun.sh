# Variables comunes de la demo. Se carga con: source ./_comun.sh
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROJECT="${PROJECT:-guardia}"
STACK="${STACK:-guardia-aiops}"
APP="${PROJECT}-app-pagos"
ONCALL="${PROJECT}-oncall"
ALARMA="${PROJECT}-app-pagos-errores"
STATE_FILE=".deploy-state"

# python3 en CloudShell/Linux, python en Windows. Si no hay ninguno, avisamos (no morimos en silencio).
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then echo "AVISO: no encontre python3/python. Algunas salidas no se formatearan." >&2; fi
