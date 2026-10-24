#!/usr/bin/env bash
# El humano aprueba desde la terminal el rollback que propuso el ingeniero de guardia N1.
#   1. Lee el ultimo diagnostico de este incidente: la misma busqueda que ver_diagnostico.sh.
#   2. Valida el comando_remediacion con la MISMA regla que el boton Aprobar de la consola web:
#      la funcion validar_rollback de src-web/control.py, leida de ese archivo (no es una copia).
#      Solo pasa un "aws lambda update-alias" de la app de pagos, alias live, a una version que
#      exista. Si no es la version estable, avisa.
#   3. Pide confirmacion y ejecuta SU PROPIO update-alias con ese numero de version.
#      El texto del modelo nunca se ejecuta.
#   4. Espera 2 s (un alias recien movido tarda un instante en propagarse) y manda 5 pagos de
#      prueba a live: cuantos salen bien y que version los atendio.
# Uso:  ./aprobar.sh                  pregunta s/N antes de tocar nada
#       APROBAR=s ./aprobar.sh        sin preguntar (para pruebas)
#       ./aprobar.sh archivo.json     un diagnostico guardado (por ejemplo, de salidas/)
set -uo pipefail
cd "$(dirname "$0")" || exit 1
source ./_comun.sh
VERIFICACIONES=5

if [ -z "$PY" ]; then
  echo "ERROR: aprobar.sh necesita python3 para leer el diagnostico y validar el comando." >&2
  exit 1
fi

# 1. El diagnostico
if [ $# -ge 1 ]; then
  if [ ! -f "$1" ]; then echo "ERROR: no existe el archivo $1." >&2; exit 1; fi
  DIAG_JSON=$(cat "$1")
  ORIGEN="del archivo $1"
else
  leer_ultimo_diagnostico
  ORIGEN="de los logs de $ONCALL"
  if [ -z "$DIAG_JSON" ]; then
    ESTADO=$(aws cloudwatch describe-alarms --alarm-names "$ALARMA" \
      --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null | tr -d '\r')
    echo "Aun no hay diagnostico de este incidente. Alarma: ${ESTADO:-?}"
    echo ""
    echo "QUE MIRAR AHORA:"
    echo "  - Si la alarma esta en OK, provoca primero el incidente: ./provocar_fallo.sh"
    echo "  - Si ya esta en ALARM, espera unos 20 s y repite (o mira la columna de ./logs.sh)."
    exit 1
  fi
fi

# 2. Leer y validar. Python imprime una linea CLAVE=valor por dato.
VALIDAR=$(cat <<'PY'
import ast, json, re, sys
app, region, control = sys.argv[1:4]

def salida(clave, valor):
    print(clave + "=" + " ".join(str(valor).split()))   # una sola linea por dato

try:
    datos = json.loads(sys.stdin.read())
except ValueError as exc:
    salida("ERROR", "el diagnostico no es JSON valido (%s)" % exc)
    sys.exit(0)
dx = datos.get("diagnostico", datos) if isinstance(datos, dict) else None
if not isinstance(dx, dict):
    salida("ERROR", "el JSON no tiene la forma de un diagnostico del N1")
    sys.exit(0)
for clave in ("severidad", "resumen", "confianza"):
    salida(clave.upper(), dx.get(clave, ""))
salida("FALSA_ALARMA", "si" if dx.get("posible_falsa_alarma") else "no")
comando = dx.get("comando_remediacion", "")
salida("COMANDO", comando if isinstance(comando, str) else json.dumps(comando))
if isinstance(comando, str) and not comando.strip():
    salida("VACIO", "si")
    sys.exit(0)

# La regla NO se copia: se toma de la Lambda de la consola web (src-web/control.py), para que la
# terminal y el boton Aprobar acepten y rechacen exactamente lo mismo.
try:
    arbol = ast.parse(open(control, encoding="utf-8").read())
    piezas = [n for n in arbol.body
              if (isinstance(n, ast.ClassDef) and n.name == "ErrorApi")
              or (isinstance(n, ast.FunctionDef) and n.name == "validar_rollback")
              or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in
                                                    ("_OPCION", "COMANDO_ROLLBACK", "FORMA") for t in n.targets))]
    regla = {"re": re, "APP": app, "REGION": region}
    exec(compile(ast.Module(body=piezas, type_ignores=[]), control, "exec"), regla)
    validar, ErrorApi = regla["validar_rollback"], regla["ErrorApi"]
except Exception as exc:  # sin la regla no se aprueba nada
    salida("ERROR", "no pude cargar la regla de %s (%s)" % (control, exc))
    sys.exit(0)
try:
    salida("VERSION", validar(comando))
except ErrorApi as exc:
    salida("RECHAZO", exc.mensaje)
PY
)
RESULTADO=$(printf '%s' "$DIAG_JSON" | "$PY" -c "$VALIDAR" "$APP" "$AWS_REGION" src-web/control.py 2>&1 | tr -d '\r')
dato() { printf '%s\n' "$RESULTADO" | sed -n "s/^$1=//p" | sed -n '1p'; }
ERROR=$(dato ERROR); RECHAZO=$(dato RECHAZO); N=$(dato VERSION); COMANDO=$(dato COMANDO)

echo "==> Diagnostico a aprobar (leido $ORIGEN)"
if [ -n "$ERROR" ] || { [ -z "$RECHAZO" ] && [ -z "$N" ] && [ -z "$(dato VACIO)" ]; }; then
  echo "    No puedo aprobar: ${ERROR:-no entendi el diagnostico ($RESULTADO)}. No cambie nada."
  exit 1
fi
echo "    Severidad : $(dato SEVERIDAD)   (confianza $(dato CONFIANZA), posible falsa alarma: $(dato FALSA_ALARMA))"
echo "    Resumen   : $(dato RESUMEN)"
echo "    Propone   : ${COMANDO:-(nada)}"
if [ -n "$(dato VACIO)" ]; then
  echo ""
  echo "El N1 no propone ningun comando: no hay nada que aprobar. No cambie nada."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Lee la causa raiz y las notas: ./ver_diagnostico.sh"
  echo "  - Si dice posible_falsa_alarma = true, la alarma vuelve sola a su estado real."
  exit 0
fi

echo "==> Validacion (la misma regla que el boton Aprobar de la consola web)"
if [ -n "$RECHAZO" ]; then
  echo "    RECHAZADO: $RECHAZO"
  echo "    No ejecute nada."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Solo se aprueba: aws lambda update-alias --function-name $APP --name live --function-version N"
  echo "  - Para volver al estado sano sin el comando del N1: ./restaurar.sh"
  exit 1
fi
if ! es_numero "$N"; then
  echo "    RECHAZADO: la version '$N' no es un numero. No ejecute nada."
  exit 1
fi
if ! VERSIONES=$(aws lambda list-versions-by-function --function-name "$APP" \
      --query 'Versions[].Version' --output text 2>&1); then
  echo "    No pude listar las versiones de $APP: $(echo "$VERSIONES" | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed -n '1p')"
  echo "    No ejecute nada."
  exit 1
fi
PUBLICADAS=$(echo "$VERSIONES" | tr -d '\r' | tr -s '[:space:]' '\n' | grep -v -e '^\$LATEST$' -e '^$')
if ! printf '%s\n' "$PUBLICADAS" | grep -qx "$N"; then
  echo "    RECHAZADO: la version $N de $APP no existe. Publicadas: $(printf '%s\n' "$PUBLICADAS" | tail -n 8 | paste -sd ' ' -)"
  echo "    No ejecute nada."
  exit 1
fi
echo "    OK: es un rollback del alias live de $APP a la version $N, que existe."
if buscar_version_estable; then
  if [ "$N" = "$ESTABLE" ]; then
    echo "    OK: v$N es la version estable (leida de $FUENTE)."
  else
    echo "    OJO: el N1 propone v$N, pero la version estable es v$ESTABLE (leida de $FUENTE)."
    echo "         Si no estas seguro, responde N y usa ./restaurar.sh, que vuelve a la estable."
  fi
else
  echo "    (No pude confirmar cual es la version estable: revisa la version antes de aprobar.)"
fi
LIVE=$(aws lambda get-alias --function-name "$APP" --name live --query FunctionVersion --output text 2>/dev/null | tr -d '\r')
if [ "$LIVE" = "$N" ]; then
  echo ""
  echo "live ya apunta a v$N: no hay nada que mover. No cambie nada."
  echo ""
  echo "QUE MIRAR AHORA:"
  echo "  - Para dejar todo sano (tambien \$LATEST) y esperar la alarma en OK: ./restaurar.sh"
  exit 0
fi

# 3. Confirmacion y ejecucion: el comando lo arma este script, con el numero ya validado.
echo "    Produccion ahora: live -> v${LIVE:-?}"
echo "    Se ejecutara (comando propio, no el texto del modelo):"
echo "      aws lambda update-alias --function-name $APP --name live --function-version $N"
RESP="${APROBAR:-}"
if [ -z "$RESP" ]; then
  read -r -p "Apruebas mover live de v${LIVE:-?} a v$N? [s/N] " RESP || RESP=""
fi
case "$RESP" in
  s|S|si|SI|Si|y|Y|yes) ;;
  *) echo "No aprobado: no cambie nada."; exit 0 ;;
esac
if ! NUEVA=$(aws lambda update-alias --function-name "$APP" --name live --function-version "$N" \
      --query FunctionVersion --output text 2>&1); then
  echo "ERROR: el update-alias fallo: $(echo "$NUEVA" | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed -n '1p')" >&2
  exit 1
fi
echo "==> Aprobado: live -> v$(echo "$NUEVA" | tr -d '\r')"

# 4. Comprobacion con trafico real, despues de dar tiempo a que el alias se propague.
sleep 2
printf "==> %d pagos de prueba a %s:live  (. = OK, x = error) " "$VERIFICACIONES" "$APP"
OK=0; ATENDIDAS=""
for _ in $(seq 1 "$VERIFICACIONES"); do
  R=$(aws lambda invoke --function-name "${APP}:live" --payload '{}' --cli-binary-format raw-in-base64-out \
       --query '[FunctionError,ExecutedVersion]' --output text /dev/null 2>/dev/null | tr -d '\r')
  ERR=$(echo "$R" | cut -f1); VER=$(echo "$R" | cut -f2)
  if [ "$ERR" = "None" ]; then OK=$((OK + 1)); printf '.'; else printf 'x'; fi
  ATENDIDAS="$ATENDIDAS ${VER:-?}"
done
echo ""
POR_VERSION=$(echo "$ATENDIDAS" | tr -s ' ' '\n' | sed '/^$/d' | sort | uniq -c \
  | awk '{printf "%sv%s (%s)", (NR>1 ? ", " : ""), $2, $1}')
echo "    Resultado: $OK de $VERIFICACIONES sin error. Las atendio: $POR_VERSION"
echo ""
echo "QUE MIRAR AHORA:"
if [ "$OK" -eq "$VERIFICACIONES" ]; then
  echo "  - Produccion responde bien con v$N. La alarma vuelve sola a OK en 1-2 min (en cuanto evalua"
  echo "    un minuto sin errores); en la consola web, Produccion pasa a SANA."
else
  echo "  - $((VERIFICACIONES - OK)) pagos fallaron: mira la columna de ./logs.sh o vuelve a la estable con ./restaurar.sh"
fi
echo "  - \$LATEST sigue con lo que dejo provocar_fallo.sh (el DB_HOST malo o el codigo con el bug):"
echo "    ./restaurar.sh lo deja como la version estable y espera a que la alarma vuelva a OK."
