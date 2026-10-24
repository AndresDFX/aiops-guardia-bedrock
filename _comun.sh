# Variables y funciones comunes de la demo. Cada script lo carga con: source ./_comun.sh
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROJECT="${PROJECT:-guardia}"
STACK="${STACK:-guardia-aiops}"
APP="${PROJECT}-app-pagos"
ONCALL="${PROJECT}-oncall"
ALARMA="${PROJECT}-app-pagos-errores"
STATE_FILE=".deploy-state"              # bucket de la ruta CloudFormation
VERSION_FILE=".version-estable"         # lo escriben los dos despliegues; lo leen restaurar.sh y aprobar.sh
TFVARS="terraform/deploy.auto.tfvars"   # opciones con las que desplego deploy.sh (Terraform lo lee solo)
TFSTATE="terraform/terraform.tfstate"
# Regiones a las que el perfil us. puede enrutar y que la politica IAM autoriza
# (local.regiones_del_perfil en terraform/main.tf e InvocarModeloBaseViaPerfil en template.yaml).
REGIONES_IAM="us-east-1 us-east-2 us-west-2"

# python3 en CloudShell/Linux, python en Windows. Si no hay ninguno, avisamos (no morimos en silencio).
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then echo "AVISO: no encontre python3/python. Algunas salidas no se formatearan." >&2; fi

es_numero() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ─────────────────────────────────────────────────────────────
# Antes de desplegar (deploy.sh y deploy-cloudformation.sh)
# ─────────────────────────────────────────────────────────────

# Cuenta, identidad y region. Deja ACCOUNT_ID listo.
comprobar_identidad() {
  local ident
  echo "==> Cuenta y region"
  if ! ident=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1); then
    echo "ERROR: esta terminal no tiene credenciales de AWS validas:" >&2
    echo "$ident" | sed '/^[[:space:]]*$/d; s/^/  /' >&2
    return 1
  fi
  ident=$(echo "$ident" | tr -d '\r')
  ACCOUNT_ID=$(echo "$ident" | cut -f1)
  echo "    Cuenta: $ACCOUNT_ID   Identidad: $(echo "$ident" | cut -f2)"
  echo "    Region: $AWS_REGION"
}

# El perfil existe en esta region, usa ese modelo base y solo enruta a regiones que la politica
# IAM autoriza. Si no, la Lambda daria AccessDenied (a veces si y a veces no) en plena demo.
comprobar_perfil() {   # $1 = perfil (us.…), $2 = modelo base
  local arns arn r destinos=""
  echo "==> Modelo: $1 (modelo base $2)"
  if ! arns=$(aws bedrock get-inference-profile --inference-profile-identifier "$1" \
        --query 'models[].modelArn' --output text 2>&1); then
    echo "ERROR: no pude leer el perfil $1 en $AWS_REGION:" >&2
    echo "$arns" | sed '/^[[:space:]]*$/d; s/^/  /' >&2
    echo "  La demo esta probada en us-east-1: export AWS_REGION=us-east-1 y repite." >&2
    return 1
  fi
  for arn in $(echo "$arns" | tr -d '\r'); do
    r=$(echo "$arn" | cut -d: -f4)
    if [ "${arn##*/}" != "$2" ]; then
      echo "ERROR: el perfil $1 no usa el modelo base $2 ($arn)." >&2
      return 1
    fi
    case " $REGIONES_IAM " in
      *" $r "*) destinos="$destinos $r" ;;
      *) echo "ERROR: desde $AWS_REGION el perfil enruta tambien a ${r:-una region global}, que la politica IAM no autoriza." >&2
         echo "  Usa us-east-1 (export AWS_REGION=us-east-1) o agrega esa region en terraform/main.tf y template.yaml." >&2
         return 1 ;;
    esac
  done
  echo "    El perfil enruta a:$destinos. La politica IAM autoriza esas regiones."
}

estado_acuerdo() {   # $1 = modelo base. AVAILABLE, PENDING, NOT_AVAILABLE... o vacio si no se pudo leer
  aws bedrock get-foundation-model-availability --model-id "$1" \
    --query agreementAvailability.status --output text 2>/dev/null | tr -d '\r'
}

# Acceso de la CUENTA al modelo. Un perfil ACTIVE no dice nada del acceso: lo dice el acuerdo
# de Marketplace. La primera llamada la hace una persona, nunca la Lambda, porque es la que crea
# la suscripcion (pide permisos de Marketplace, un metodo de pago y, con Anthropic, el formulario).
comprobar_acceso_modelo() {   # $1 = perfil, $2 = modelo base
  local ciclo estado salida
  ciclo=$(aws bedrock get-foundation-model --model-identifier "$2" \
    --query modelDetails.modelLifecycle.status --output text 2>/dev/null | tr -d '\r')
  estado=$(estado_acuerdo "$2")
  echo "    Ciclo de vida del modelo: ${ciclo:-?}   Acuerdo de la cuenta: ${estado:-no lo pude leer}"
  if [ -n "$ciclo" ] && [ "$ciclo" != "ACTIVE" ]; then
    echo "    AVISO: el modelo esta en $ciclo. Las cuentas que no lo venian usando no pueden adoptarlo."
  fi
  if [ "$estado" != "AVAILABLE" ]; then
    echo "==> Primera invocacion del modelo, con tu usuario (activa el acuerdo de Marketplace)"
    if ! salida=$(aws bedrock-runtime converse --model-id "$1" \
          --messages '[{"role":"user","content":[{"text":"Responde solo con la palabra: listo"}]}]' \
          --query 'output.message.content[?text].text | [0]' --output text 2>&1); then
      explicar_error_bedrock "$salida" "$2"
      return 1
    fi
    echo "    El modelo respondio: $(echo "$salida" | tr -d '\r' | sed -n '1p')"
    if [ -n "$estado" ]; then
      printf "    Esperando a que el acuerdo pase a AVAILABLE (max. 5 min) "
      for _ in $(seq 1 30); do
        estado=$(estado_acuerdo "$2")
        [ "$estado" = "AVAILABLE" ] && break
        printf '.'; sleep 10
      done
      echo " ${estado:-?}"
      if [ "$estado" != "AVAILABLE" ]; then
        echo "ERROR: el modelo respondio, pero el acuerdo sigue en ${estado:-?} tras 5 min." >&2
        echo "QUE MIRAR AHORA (no se desplego nada):"
        echo "  - AWS tarda a veces mas. Repite ./deploy.sh en unos minutos: no crea nada dos veces."
        return 1
      fi
    fi
  fi
  comprobar_cuota "$2"
}

# Un acuerdo AVAILABLE tampoco basta: con la cuota de tokens por minuto en 0, cada llamada da
# "is not available for this account" (le paso a Sonnet 5.5 en la cuenta del laboratorio).
# Es la cuota del perfil us. ("Cross-region model inference tokens per minute"). Consultarla es gratis.
comprobar_cuota() {   # $1 = modelo base
  local codigo="" valor="" nombre=""
  case "$1" in
    anthropic.claude-sonnet-4-6) codigo="L-15B8E632" ;;   # el de la demo: 1 s
  esac
  if [ -n "$codigo" ]; then
    valor=$(aws service-quotas get-service-quota --service-code bedrock --quota-code "$codigo" \
      --query 'Quota.Value' --output text 2>/dev/null | tr -d '\r')
  elif [ -n "$PY" ]; then
    # Otro modelo: se busca la cuota por su nombre (~30 s, Bedrock tiene cientos de cuotas).
    nombre=$(aws bedrock get-foundation-model --model-identifier "$1" \
      --query 'modelDetails.[providerName,modelName]' --output text 2>/dev/null | tr -d '\r' | tr '\t' ' ')
    echo "    Buscando la cuota de $nombre en Service Quotas (~30 s)"
    valor=$(aws service-quotas list-service-quotas --service-code bedrock --output json \
      --query "Quotas[?QuotaName=='Cross-region model inference tokens per minute for $nombre'].Value" 2>/dev/null \
      | "$PY" -c "import json,sys; v=json.load(sys.stdin); print(v[0] if v else '')" 2>/dev/null | tr -d '\r')
  fi
  valor=${valor%.*}
  if ! es_numero "$valor"; then
    echo "    (No pude leer la cuota del modelo en Service Quotas: sigo. Si el diagnostico dice"
    echo "     'not available for this account', es la cuota de tokens por minuto.)"
    return 0
  fi
  if [ "$valor" -le 0 ]; then
    echo "ERROR: tu cuenta tiene cuota 0 de tokens por minuto para $1 (perfil us.)." >&2
    echo "QUE MIRAR AHORA (no se desplego nada):"
    echo "  - Con la cuota en 0, Bedrock responde 'is not available for this account' aunque el acuerdo"
    echo "    diga AVAILABLE. No hay arreglo rapido: Service Quotas no acepta pedir menos que el valor"
    echo "    por defecto, y pedir mas pasa a revision de AWS. Usa otra cuenta, u otro modelo con cuota."
    return 1
  fi
  echo "    Cuota de la cuenta: $valor tokens por minuto (perfil us.). Acceso al modelo: listo."
}

# Lo que dice Bedrock en la primera llamada, traducido a que hacer.
explicar_error_bedrock() {   # $1 = salida de la CLI, $2 = modelo base
  echo "ERROR: la primera llamada al modelo fallo. Bedrock respondio:" >&2
  echo "$1" | sed '/^[[:space:]]*$/d; s/^/  /' | sed -n '1,6p' >&2
  echo ""
  echo "QUE MIRAR AHORA (no se desplego nada):"
  case "$1" in
    *"use case details"*)
      echo "  - Falta el formulario de caso de uso de Anthropic (una vez por cuenta). En la consola:"
      echo "    Amazon Bedrock -> Model catalog -> el modelo -> Submit use case details."
      echo "    Envialo, espera unos minutos y repite ./deploy.sh." ;;
    *"still being processed"*)
      echo "  - La suscripcion de Marketplace al modelo todavia se esta procesando."
      echo "    Espera unos minutos y repite ./deploy.sh." ;;
    *[Pp][Aa][Yy][Mm][Ee][Nn][Tt]*)
      echo "  - La cuenta no tiene un metodo de pago valido. Claude se cobra por AWS Marketplace, que el"
      echo "    plan Free no incluye: Billing and Cost Management -> Payment preferences. Luego repite."
      echo "    (Si lo acabas de arreglar, AWS pide esperar unos 15 min.)" ;;
    *"aws-marketplace"*)
      echo "  - Tu usuario no puede suscribirse en AWS Marketplace (aws-marketplace:Subscribe,"
      echo "    Unsubscribe y ViewSubscriptions). Usa un usuario administrador o pide esos permisos." ;;
    *"not available for this account"*)
      echo "  - Tu cuenta tiene cuota 0 para este modelo (tokens por minuto en Service Quotas)."
      echo "    No hay arreglo rapido: usa otra cuenta, u otro modelo con cuota." ;;
    *"model identifier is invalid"*|*"not found"*|*"NotFound"*)
      echo "  - El modelo o su perfil no existen en $AWS_REGION. La demo esta probada en us-east-1:"
      echo "    export AWS_REGION=us-east-1 y repite ./deploy.sh." ;;
    *[Ll]egacy*|*"end of its life"*)
      echo "  - El modelo esta en Legacy: las cuentas que no lo venian usando no pueden adoptarlo."
      echo "    Usa un modelo activo (MODEL_ID y FOUNDATION_MODEL_ID, ver la cabecera de deploy.sh)." ;;
    *Throttling*|*"Too many"*)
      echo "  - Bedrock limito la llamada (cuota de peticiones por minuto). Espera un minuto y repite." ;;
    *"not authorized to perform"*|*AccessDenied*)
      echo "  - Tu usuario no tiene permiso para invocar el modelo (bedrock:InvokeModel)."
      echo "    Usa un usuario administrador de la cuenta de pruebas." ;;
    *)
      echo "  - Lee el mensaje de arriba. La guia del participante tiene una tabla con los errores comunes." ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Terraform en CloudShell (deploy.sh y destroy.sh)
# ─────────────────────────────────────────────────────────────

# Lee una opcion de terraform/deploy.auto.tfvars. Vacio si no esta.
previo() {
  [ -f "$TFVARS" ] || return 0
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$TFVARS" | tail -n 1
}

# Cuantos recursos tiene el estado de Terraform (instancias). 0 si no hay estado.
recursos_en_estado() {
  local n
  if [ ! -f "$TFSTATE" ]; then echo 0; return; fi
  if [ -z "$PY" ]; then echo "?"; return; fi
  n=$("$PY" -c "import json,sys; r=json.load(open(sys.argv[1])).get('resources',[]); print(sum(len(x.get('instances',[])) for x in r if x.get('mode')=='managed'))" \
    "$TFSTATE" 2>/dev/null | tr -d '\r')
  if es_numero "$n"; then echo "$n"; else echo "?"; fi
}

# CloudShell no trae Terraform y lo pierde al cerrar la sesion: va a /usr/bin, fuera de $HOME.
instalar_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    echo "==> Terraform: $(terraform version | sed -n '1p')"
    return 0
  fi
  if ! grep -qs '^ID="\{0,1\}amzn' /etc/os-release; then
    echo "ERROR: no encontre terraform y este sistema no es Amazon Linux (CloudShell): no lo instalo solo." >&2
    echo "QUE MIRAR AHORA:"
    echo "  - Instala Terraform 1.5 o mas nuevo (https://developer.hashicorp.com/terraform/install) y repite."
    echo "  - O corre este script en AWS CloudShell, donde se instala solo."
    return 1
  fi
  echo "==> Instalando Terraform (CloudShell no lo trae y lo borra al cerrar la sesion; ~1 min)"
  # Los comandos oficiales de HashiCorp para Amazon Linux, con -y en el ultimo para no preguntar.
  # En CloudShell van con sudo; en un contenedor que corre como root no hay sudo ni hace falta.
  como_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
  if ! { como_root yum install -y -q yum-utils shadow-utils &&
         como_root yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo >/dev/null &&
         como_root yum -y -q install terraform; }; then
    echo "ERROR: no pude instalar Terraform (arriba el detalle)." >&2
    return 1
  fi
  echo "    $(terraform version | sed -n '1p') instalado."
}

# Terraform instalado, cache de providers en /tmp e init. Sirve igual en una sesion nueva.
preparar_terraform() {
  local log
  instalar_terraform || return 1
  # El provider de AWS pesa ~800 MB y $HOME en CloudShell tiene 1 GB: la cache va en /tmp.
  # El precio: en cada sesion nueva hay que repetir el init (este script lo hace solo).
  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-/tmp/terraform-plugins}"
  export TF_IN_AUTOMATION=1
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  echo "==> terraform init (providers en $TF_PLUGIN_CACHE_DIR; ~40 s si la cache esta vacia)"
  log=$(mktemp)
  if ! terraform -chdir=terraform init -input=false -no-color 2>&1 | tee "$log" \
       | awk '/^- (Installing|Installed|Using|Reusing)/ { print "    " $0; fflush() }'; then
    cat "$log"; rm -f "$log"
    echo "ERROR: terraform init fallo (arriba el detalle)." >&2
    return 1
  fi
  rm -f "$log"
}

# Muestra de la salida de Terraform solo el avance y los errores; el detalle completo va a $1.
terraform_resumido() {   # $1 = archivo de log, resto = argumentos de terraform
  local log="$1"; shift
  terraform -chdir=terraform "$@" -input=false -no-color 2>&1 | tee "$log" | awk '
    /^(Plan:|Apply complete!|Destroy complete!|No changes\.)/ ||
    /: (Creating|Creation complete|Modifying|Modifications complete|Destroying|Destruction complete|Still [a-z]+)/ ||
    /^(╷|│|╵)/ { print "    " $0; fflush() }'
}

# ─────────────────────────────────────────────────────────────
# Durante la demo
# ─────────────────────────────────────────────────────────────

# La version estable sale del despliegue: Lambda no reinicia la numeracion al recrear la funcion.
# Deja ESTABLE y FUENTE. Se busca en este orden:
#   1. .version-estable, que escriben los dos despliegues. Vive en $HOME, asi que sobrevive a un
#      reinicio de CloudShell aunque Terraform ya no este instalado.
#   2. El Output StableVersion del stack de CloudFormation.
#   3. terraform output stable_version (pide Terraform instalado y el init hecho).
#   4. El mismo output, leido del estado de Terraform con python.
#   5. La configuracion desplegada del ingeniero de guardia: el despliegue le pasa la estable en la
#      variable STABLE_VERSIONS. Sirve en una sesion sin el estado ni el archivo (por ejemplo, si
#      desplegaste desde tu portatil y restauras desde CloudShell).
buscar_version_estable() {
  ESTABLE=""; FUENTE=""
  if [ -f "$VERSION_FILE" ]; then
    ESTABLE=$(tr -d ' \r\n' < "$VERSION_FILE"); FUENTE="$VERSION_FILE"
  fi
  if ! es_numero "$ESTABLE"; then
    ESTABLE=$(aws cloudformation describe-stacks --stack-name "$STACK" \
      --query "Stacks[0].Outputs[?OutputKey=='StableVersion'].OutputValue" --output text 2>/dev/null | tr -d '\r')
    FUENTE="Output StableVersion del stack"
  fi
  if ! es_numero "$ESTABLE" && [ -d terraform ] && command -v terraform >/dev/null 2>&1; then
    ESTABLE=$(terraform -chdir=terraform output -raw stable_version 2>/dev/null | tr -d '\r')
    FUENTE="terraform output"
  fi
  if ! es_numero "$ESTABLE" && [ -f "$TFSTATE" ] && [ -n "$PY" ]; then
    ESTABLE=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['outputs']['stable_version']['value'])" \
      "$TFSTATE" 2>/dev/null | tr -d '\r')
    FUENTE="$TFSTATE"
  fi
  if ! es_numero "$ESTABLE" && [ -n "$PY" ]; then
    ESTABLE=$(aws lambda get-function-configuration --function-name "$ONCALL" \
      --query 'Environment.Variables.STABLE_VERSIONS' --output text 2>/dev/null | tr -d '\r' \
      | "$PY" -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ''))" "$APP" 2>/dev/null | tr -d '\r')
    FUENTE="la variable STABLE_VERSIONS de la Lambda $ONCALL"
  fi
  es_numero "$ESTABLE"
}

# Compara el $LATEST de la app con una version: codigo (CodeSha256) y DB_HOST. Lo usan
# provocar_fallo.sh, que no rompe sobre un fallo anterior sin restaurar (la version nueva
# arrastraria los dos problemas), y restaurar.sh. Deja en DIF lo que cambia ("codigo",
# "DB_HOST" o "codigo y DB_HOST") y devuelve 0 si no cambia nada.
comparar_con_version() {   # $1 = version
  local a b
  a=$(aws lambda get-function-configuration --function-name "$APP" \
    --query '[CodeSha256,Environment.Variables.DB_HOST]' --output text | tr -d '\r')
  b=$(aws lambda get-function-configuration --function-name "$APP" --qualifier "$1" \
    --query '[CodeSha256,Environment.Variables.DB_HOST]' --output text | tr -d '\r')
  DIF=""
  [ "$(echo "$a" | cut -f1)" != "$(echo "$b" | cut -f1)" ] && DIF="codigo"
  [ "$(echo "$a" | cut -f2)" != "$(echo "$b" | cut -f2)" ] && DIF="${DIF:+$DIF y }DB_HOST"
  [ -z "$DIF" ]
}

# El ultimo DIAGNOSTICO_JSON del N1 desde el ultimo incidente provocado (.ultimo-incidente) o, si
# no hay, de los ultimos MIN minutos. Lo usan ver_diagnostico.sh y aprobar.sh: la misma fuente.
# Deja en DIAG_JSON el JSON (vacio si aun no hay) y en DESDE el instante (ms) desde el que busco.
leer_ultimo_diagnostico() {
  local linea
  DESDE=$(( ( $(date +%s) - ${MIN:-20}*60 ) * 1000 ))
  # Solo diagnosticos posteriores al ultimo incidente: si repites la demo, no quieres el de antes.
  if [ -f .ultimo-incidente ]; then DESDE=$(tr -d ' \r\n' < .ultimo-incidente); fi
  # --output json (no text): con text el CLI aplica el --query pagina a pagina y la ultima,
  # vacia, anade un "None" que rompe el JSON. En json primero junta todas las paginas.
  linea=$(aws logs filter-log-events --log-group-name "/aws/lambda/$ONCALL" \
    --start-time "$DESDE" --filter-pattern '"DIAGNOSTICO_JSON"' \
    --query 'events[].message' --output json 2>/dev/null \
    | "$PY" -c "import json,sys; m=json.load(sys.stdin) or ['']; print(m[-1].strip())" 2>/dev/null | tr -d '\r')
  DIAG_JSON="${linea#*DIAGNOSTICO_JSON: }"
}

# ─────────────────────────────────────────────────────────────
# Despues de borrar (destroy.sh y destroy-cloudformation.sh)
# ─────────────────────────────────────────────────────────────

# Consulta los recursos, no el stack ni el estado: un destroy puede decir "listo" y dejar cosas
# vivas (el de una ruta de IaC no borra lo de la otra). Devuelve 1 si queda algo.
verificar_limpieza() {
  local quedan=0
  echo "==> Comprobando en la cuenta que no quedo nada de la demo ($PROJECT-*, $AWS_REGION)"
  _revisar() {   # $1 = que es, resto = consulta de la CLI
    local que="$1" salida rc
    shift
    salida=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      quedan=$((quedan+1))
      printf '    %-26s NO PUDE CONSULTAR: %s\n' "$que" "$(echo "$salida" | tr -d '\r' | sed '/^[[:space:]]*$/d' | sed -n '1p')"
      return
    fi
    salida=$(echo "$salida" | tr -d '\r' | tr '\t' '\n' | grep -v -e '^None$' -e '^[[:space:]]*$' | tr '\n' ' ')
    if [ -n "$salida" ]; then
      quedan=$((quedan+1))
      printf '    %-26s QUEDA: %s\n' "$que" "$salida"
    else
      printf '    %-26s ninguno\n' "$que"
    fi
  }
  _revisar "Funciones Lambda" aws lambda list-functions --output text \
    --query "Functions[?starts_with(FunctionName, '$PROJECT-')].FunctionName"
  _revisar "Alarmas" aws cloudwatch describe-alarms --alarm-name-prefix "$PROJECT-" --output text \
    --query 'MetricAlarms[].AlarmName'
  _revisar "Log groups" aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$PROJECT-" --output text \
    --query 'logGroups[].logGroupName'
  _revisar "Reglas de EventBridge" aws events list-rules --name-prefix "$PROJECT-" --output text \
    --query 'Rules[].Name'
  _revisar "Topics de SNS" aws sns list-topics --output text \
    --query "Topics[?contains(TopicArn, ':$PROJECT-')].TopicArn"
  _revisar "Roles de IAM" aws iam list-roles --output text \
    --query "Roles[?starts_with(RoleName, '$PROJECT-')].RoleName"
  _revisar "Buckets de S3" aws s3api list-buckets --output text \
    --query "Buckets[?starts_with(Name, '$PROJECT-')].Name"
  _revisar "Distribuciones CloudFront" aws cloudfront list-distributions --output text \
    --query "DistributionList.Items[?starts_with(Comment, '$PROJECT - ')].Id"
  _revisar "Origin access control" aws cloudfront list-origin-access-controls --output text \
    --query "OriginAccessControlList.Items[?starts_with(Name, '$PROJECT-')].Name"
  _revisar "HTTP APIs" aws apigatewayv2 get-apis --output text \
    --query "Items[?starts_with(Name, '$PROJECT-')].Name"
  _revisar "Stack de CloudFormation" aws cloudformation list-stacks --output text \
    --query "StackSummaries[?StackName=='$STACK' && StackStatus!='DELETE_COMPLETE'].StackName"
  if [ "$quedan" -eq 0 ]; then
    echo "    Limpio: no queda ningun recurso de la demo."
    return 0
  fi
  return 1
}
