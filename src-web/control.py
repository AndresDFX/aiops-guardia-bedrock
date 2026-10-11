"""
Consola web de Guardia N1: las manos del humano.

El ingeniero de guardia N1 (guardia-oncall) tiene un rol de SOLO LECTURA: propone y no
ejecuta. Esta Lambda es la que cambia cosas, y solo cuando alguien pulsa un boton de la
consola con el PIN de la demo. Hace lo mismo que los scripts de la terminal:

  GET  /api/estado        produccion (alias live), alarma y errores por minuto
  GET  /api/diagnostico   ultimo DIAGNOSTICO_JSON del N1 desde un instante  (ver_diagnostico.sh)
  POST /api/provocar      mal despliegue real                                (provocar_fallo.sh)  PIN
  POST /api/simular       alarma forzada sin errores nuevos                  (simular_alarma.sh)  PIN
  POST /api/aprobar       el rollback que propuso el N1, si y solo si es un
                          update-alias de live en la app de pagos                                 PIN
  POST /api/restaurar     vuelta al estado sano                              (restaurar.sh)       PIN

/api/aprobar NO ejecuta comandos: valida el texto con una expresion estricta y llama a
UpdateAlias con el SDK. Cualquier otra cosa se rechaza con 400 y el motivo.
"""

import base64
import hmac
import json
import os
import re
import time
import traceback
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, WaiterError

APP = os.environ.get("APP_NAME", "guardia-app-pagos")
ALARMA = os.environ.get("ALARM_NAME", "guardia-app-pagos-errores")
LOG_ONCALL = os.environ.get("ONCALL_LOG_GROUP", "/aws/lambda/guardia-oncall")
ESTABLE = os.environ.get("STABLE_VERSION", "")   # la congela Terraform en terraform_data
PIN = os.environ.get("DEMO_PIN", "")
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Los mismos valores que los scripts de la terminal.
HOST_MALO = os.environ.get("HOST_MALO", "db-pagos.prod.internal")     # provocar_fallo.sh
PETICIONES = int(os.environ.get("PETICIONES", "12"))                   # provocar_fallo.sh
MOTIVO_SIMULADA = "Prueba manual: alarma forzada con set-alarm-state"  # simular_alarma.sh
VERIFICACIONES = 5            # invocaciones de prueba despues de aprobar el rollback
VENTANA_MIN = 20              # ver_diagnostico.sh: MIN=20 si no hay instante del incidente
# Un alias recien movido tarda un instante en llegar a todas partes: medido el 10-oct, la
# primera invocacion lanzada justo despues de UpdateAlias la atendio la version ANTERIOR.
# En la terminal no se nota porque cada comando de la CLI tarda ~1 s en arrancar.
ESPERA_ALIAS_S = 2.0

_cfg = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=3, read_timeout=10)
lam = boto3.client("lambda", config=_cfg)
cw = boto3.client("cloudwatch", config=_cfg)
logs = boto3.client("logs", config=_cfg)

_CUENTA = ""      # se lee del ARN de la propia funcion: nunca sale en una respuesta
_cache = {}       # clave -> (caduca, valor). Vive mientras viva el entorno de la Lambda.


class ErrorApi(Exception):
    """Error con codigo HTTP y un mensaje que se puede mostrar en pantalla."""

    def __init__(self, codigo, mensaje, **extra):
        super().__init__(mensaje)
        self.codigo = codigo
        self.mensaje = mensaje
        self.extra = extra


# ─────────────────────────────────────────────────────────────
# Utilidades
# ─────────────────────────────────────────────────────────────
def _ahora_ms():
    return int(time.time() * 1000)


def _ms(dt):
    return int(dt.timestamp() * 1000)


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cacheado(clave, segundos, leer):
    """
    El plano de control de Lambda admite 15 llamadas por segundo para TODA la cuenta y
    DescribeAlarms, 9. Una URL proyectada en una sala puede abrirse en muchas pestanas:
    sin esta cache, cada una gastaria su parte del cupo en cada sondeo (cada 3 s en un incidente).
    """
    ahora = time.monotonic()
    guardado = _cache.get(clave)
    if guardado and guardado[0] > ahora:
        return guardado[1]
    valor = leer()
    _cache[clave] = (ahora + segundos, valor)
    return valor


def _olvidar_estado():
    _cache.pop("estado", None)


_ARN_CON_CUENTA = re.compile(r"(arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:)\d{12}")


def _sin_cuenta(dato):
    """Ningun ID de cuenta ni ARN con la cuenta llega a la pantalla."""
    if isinstance(dato, str):
        dato = _ARN_CON_CUENTA.sub(r"\1<cuenta>", dato)
        return dato.replace(_CUENTA, "<cuenta>") if _CUENTA else dato
    if isinstance(dato, list):
        return [_sin_cuenta(x) for x in dato]
    if isinstance(dato, dict):
        return {k: _sin_cuenta(v) for k, v in dato.items()}
    return dato


def _respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
        "body": json.dumps(_sin_cuenta(cuerpo), ensure_ascii=False),
    }


def _cuerpo(event):
    crudo = event.get("body") or ""
    if not crudo:
        return {}
    if event.get("isBase64Encoded"):
        crudo = base64.b64decode(crudo).decode("utf-8", "replace")
    try:
        datos = json.loads(crudo)
    except json.JSONDecodeError:
        raise ErrorApi(400, "El cuerpo de la peticion no es JSON valido.")
    if not isinstance(datos, dict):
        raise ErrorApi(400, "El cuerpo tiene que ser un objeto JSON.")
    return datos


def _exigir_pin(event):
    if not PIN:
        raise ErrorApi(500, "La consola no tiene PIN configurado (variable DEMO_PIN de la Lambda).")
    dado = (event.get("headers") or {}).get("x-pin", "")
    if not dado:
        raise ErrorApi(401, "Falta el PIN. Lo da: terraform -chdir=terraform output -raw web_pin")
    if not hmac.compare_digest(dado.encode(), PIN.encode()):
        raise ErrorApi(401, "PIN incorrecto.")


# ─────────────────────────────────────────────────────────────
# Lecturas
# ─────────────────────────────────────────────────────────────
def _version(v):
    """Descripcion y DB_HOST de una version publicada. Una version no cambia: se cachea."""
    def leer():
        c = lam.get_function_configuration(FunctionName=APP, Qualifier=v)
        variables = (c.get("Environment") or {}).get("Variables") or {}
        modificada = c.get("LastModified")  # "2026-10-10T19:45:56.000+0000"
        try:
            publicada_ms = _ms(datetime.strptime(modificada, "%Y-%m-%dT%H:%M:%S.%f%z"))
        except (TypeError, ValueError):
            publicada_ms = None
        return {"version": c.get("Version", v), "descripcion": c.get("Description", ""),
                "db_host": variables.get("DB_HOST", ""), "publicada_ms": publicada_ms}
    return _cacheado(f"version:{v}", 3600, leer)


def _live():
    return lam.get_alias(FunctionName=APP, Name="live")["FunctionVersion"]


def _alarma():
    r = cw.describe_alarms(AlarmNames=[ALARMA], AlarmTypes=["MetricAlarm"])
    alarmas = r.get("MetricAlarms") or []
    if not alarmas:
        raise ErrorApi(404, f"No existe la alarma {ALARMA}.")
    a = alarmas[0]
    t = a["StateUpdatedTimestamp"]
    return {"nombre": ALARMA, "estado": a.get("StateValue"), "motivo": a.get("StateReason", ""),
            "desde": _iso(t), "desde_ms": _ms(t)}


def _errores_por_minuto(minutos=10):
    """
    Invocaciones y errores de la app de pagos, minuto a minuto (todas las versiones).
    GetMetricStatistics, una peticion por metrica: entra en el millon de peticiones gratis al mes
    de CloudWatch. GetMetricData no: se cobra desde la primera metrica (USD 0,01 por 1 000).
    """
    fin = datetime.now(timezone.utc).replace(second=0, microsecond=0) + timedelta(minutes=1)
    ini = fin - timedelta(minutes=minutos)
    dims = [{"Name": "FunctionName", "Value": APP}]

    def serie(metrica):
        # Los puntos llegan sin orden: se indexan por su minuto.
        r = cw.get_metric_statistics(Namespace="AWS/Lambda", MetricName=metrica, Dimensions=dims,
                                     StartTime=ini, EndTime=fin, Period=60, Statistics=["Sum"])
        return {_ms(p["Timestamp"]): p["Sum"] for p in r.get("Datapoints", [])}

    invocaciones, errores = serie("Invocations"), serie("Errors")
    puntos = []
    for i in range(minutos):
        t = _ms(ini + timedelta(minutes=i))
        puntos.append({"ms": t, "invocaciones": int(invocaciones.get(t, 0)),
                       "errores": int(errores.get(t, 0))})
    return puntos


def estado():
    def leer():
        live = _live()
        v_live = _version(live)
        v_estable = _version(ESTABLE) if ESTABLE else {"descripcion": "", "db_host": ""}
        if live == ESTABLE:
            salud = "sana"
        elif v_live["db_host"] != v_estable["db_host"]:
            salud = "rota"
        else:
            salud = "distinta"     # otra version, con la misma configuracion que la estable
        # El dato es por minuto y llega con 1-2 min de retraso: pedirlo en cada sondeo no aporta
        # nada. Con 30 s de cache son como mucho 2 peticiones a CloudWatch por minuto y entorno.
        puntos = _cacheado("metricas", 30, _errores_por_minuto)
        return {
            "produccion": {
                "funcion": APP, "salud": salud,
                "live": live, "live_descripcion": v_live["descripcion"],
                "live_db_host": v_live["db_host"], "live_publicada_ms": v_live["publicada_ms"],
                "estable": ESTABLE, "estable_descripcion": v_estable["descripcion"],
                "estable_db_host": v_estable["db_host"],
            },
            "alarma": _alarma(),
            "metricas": puntos,
            "ahora_ms": _ahora_ms(),
        }
    return _cacheado("estado", 2, leer)


def _ultimo_evento(patron, desde_ms):
    ultimo = None
    paginas = logs.get_paginator("filter_log_events").paginate(
        logGroupName=LOG_ONCALL, startTime=desde_ms, filterPattern=patron,
        PaginationConfig={"MaxItems": 200})
    for pagina in paginas:
        for e in pagina.get("events", []):
            if ultimo is None or e["timestamp"] >= ultimo["timestamp"]:
                ultimo = e
    return ultimo


def diagnostico(desde_ms):
    """La misma busqueda que ver_diagnostico.sh: el ultimo DIAGNOSTICO_JSON desde el incidente."""
    def leer():
        try:
            e = _ultimo_evento('"DIAGNOSTICO_JSON"', desde_ms)
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ResourceNotFoundException":
                return {"listo": False, "aviso": f"El log group {LOG_ONCALL} todavia no existe."}
            raise
        if e:
            texto = e["message"].strip()
            crudo = texto.split("DIAGNOSTICO_JSON: ", 1)[-1]
            try:
                resultado = json.loads(crudo)
            except json.JSONDecodeError:
                return {"listo": False, "aviso": "El diagnostico del N1 no es JSON valido."}
            return {"listo": True, "hora_ms": e["timestamp"], "resultado": resultado}
        # Si el N1 ya fallo (sin acceso al modelo, cuota en 0, throttling), su log lo dice:
        # no tiene sentido que la pantalla siga diciendo "esperando".
        fallo = _ultimo_evento('"[guardia] ERROR"', desde_ms)
        if fallo:
            return {"listo": False, "fallo_n1": fallo["message"].strip()[:400], "hora_ms": fallo["timestamp"]}
        return {"listo": False}
    return _cacheado(f"diagnostico:{desde_ms}", 3, leer)


# ─────────────────────────────────────────────────────────────
# Acciones (todas piden PIN)
# ─────────────────────────────────────────────────────────────
def _invocar_live():
    """Una peticion de cliente a app-pagos:live: ('.', version) si responde bien, ('x', version) si falla."""
    try:
        r = lam.invoke(FunctionName=f"{APP}:live", Payload=b"{}")
        r["Payload"].read()
    except ClientError:
        return "x", "?"
    return ("x" if r.get("FunctionError") else "."), r.get("ExecutedVersion", "?")


def _trafico(peticiones, alias_movido):
    """
    Manda peticiones a live y cuenta que version atendio cada una (ExecutedVersion).
    Antes espera a que el alias recien movido se propague (ver ESPERA_ALIAS_S).
    """
    falta = ESPERA_ALIAS_S - (time.monotonic() - alias_movido)
    if falta > 0:
        time.sleep(falta)
    resultados = [_invocar_live() for _ in range(peticiones)]
    atendidas = {}
    for _, version in resultados:
        atendidas[version] = atendidas.get(version, 0) + 1
    trafico = "".join(r for r, _ in resultados)
    return {"trafico": trafico, "ok": trafico.count("."), "errores": trafico.count("x"),
            "atendidas_por": atendidas}


def _cambiar_db_host(host):
    lam.update_function_configuration(
        FunctionName=APP, Environment={"Variables": {"DB_HOST": host, "DB_PORT": "5432"}})
    lam.get_waiter("function_updated").wait(FunctionName=APP, WaiterConfig={"Delay": 1, "MaxAttempts": 25})


def provocar():
    """provocar_fallo.sh: version nueva con un DB_HOST que no existe, live a esa version y trafico."""
    if _alarma()["estado"] == "ALARM":
        raise ErrorApi(409, "La alarma ya esta en ALARM. Espera a que vuelva a OK: EventBridge solo "
                            "avisa cuando la alarma cambia de estado y no llegaria un diagnostico nuevo.")
    antes = _live()
    if ESTABLE and antes != ESTABLE:
        raise ErrorApi(409, f"Produccion ya no esta en la version estable (live apunta a v{antes}). "
                            "Aprueba el rollback o pulsa Restaurar antes de romperla otra vez.")
    desde = _ahora_ms()     # como .ultimo-incidente: el diagnostico se busca desde aqui
    _cambiar_db_host(HOST_MALO)
    nueva = lam.publish_version(FunctionName=APP,
                                Description=f"release viernes 6pm (DB_HOST={HOST_MALO})")["Version"]
    lam.update_alias(FunctionName=APP, Name="live", FunctionVersion=nueva)
    movido = time.monotonic()
    despliegue = _ahora_ms()
    trafico = _trafico(PETICIONES, movido)
    _olvidar_estado()
    return {"desde": desde, "despliegue_ms": despliegue, "version_antes": antes, "version_nueva": nueva,
            "db_host": HOST_MALO, "peticiones": PETICIONES, **trafico,
            "siguiente": "La alarma tarda de 1 a 3 min en pasar a ALARM (la metrica de Lambda es por "
                         "minuto). El diagnostico aparece de 10 a 30 s despues."}


def simular():
    """simular_alarma.sh: fuerza la alarma a ALARM sin errores nuevos (prueba de falsa alarma)."""
    if _alarma()["estado"] == "ALARM":
        raise ErrorApi(409, "La alarma ya esta en ALARM: forzarla otra vez no cambia su estado y "
                            "EventBridge no avisaria. Espera a que vuelva a OK.")
    live = _live()
    if ESTABLE and live != ESTABLE:
        raise ErrorApi(409, f"La falsa alarma se prueba con produccion sana, y live apunta a v{live}. "
                            "Pulsa Restaurar primero.")
    desde = _ahora_ms()
    cw.set_alarm_state(AlarmName=ALARMA, StateValue="ALARM", StateReason=MOTIVO_SIMULADA)
    _olvidar_estado()
    return {"desde": desde, "motivo": MOTIVO_SIMULADA,
            "siguiente": "El diagnostico aparece en 10 a 30 s. Sin errores nuevos, espera "
                         "posible_falsa_alarma = true. La alarma vuelve sola a su estado real en la "
                         "siguiente evaluacion (medido: de 20 a 95 s)."}


# Lo unico que se aprueba: aws lambda update-alias con exactamente --function-name, --name y
# --function-version (y --region, opcional), en cualquier orden, como "--opcion valor" o
# "--opcion=valor". Sin comillas, punto y coma, tuberias, $ ni nada que un shell interprete.
_OPCION = r"--(?:function-name|name|function-version|region)(?:=|\s+)[A-Za-z0-9._:-]+"
COMANDO_ROLLBACK = re.compile(r"^aws\s+lambda\s+update-alias((?:\s+" + _OPCION + r"){3,4})\s*$")
FORMA = ("aws lambda update-alias --function-name {app} --name live --function-version N "
         "[--region {region}]")


def validar_rollback(comando):
    """Devuelve la version N si el comando es exactamente el rollback permitido. Si no, ErrorApi(400)."""
    if not isinstance(comando, str) or not comando.strip():
        raise ErrorApi(400, "Falta el comando a aprobar (campo 'comando').")
    comando = comando.strip()
    forma = FORMA.format(app=APP, region=REGION)
    if len(comando) > 300:
        raise ErrorApi(400, "El comando es demasiado largo para ser un rollback del alias.")
    m = COMANDO_ROLLBACK.match(comando)
    if not m:
        raise ErrorApi(400, f"Solo apruebo un rollback del alias, con esta forma: {forma}. "
                            "Este comando no la tiene.")
    opciones = {}
    for clave, valor in re.findall(r"--([a-z-]+)(?:=|\s+)(\S+)", m.group(1)):
        if clave in opciones:
            raise ErrorApi(400, f"--{clave} aparece dos veces.")
        opciones[clave] = valor
    if not {"function-name", "name", "function-version"} <= set(opciones):
        raise ErrorApi(400, f"Faltan opciones. La forma es: {forma}.")
    if opciones["function-name"] != APP:
        raise ErrorApi(400, f"Solo apruebo cambios en {APP}, y el comando apunta a {opciones['function-name']}.")
    if opciones["name"] != "live":
        raise ErrorApi(400, f"Solo apruebo mover el alias live, y el comando mueve {opciones['name']}.")
    if not re.fullmatch(r"[0-9]{1,6}", opciones["function-version"]):
        raise ErrorApi(400, "--function-version tiene que ser un numero de version publicada.")
    if "region" in opciones and opciones["region"] != REGION:
        raise ErrorApi(400, f"La demo vive en {REGION}, y el comando apunta a {opciones['region']}.")
    return str(int(opciones["function-version"]))


def aprobar(cuerpo):
    """El humano aprueba el comando_remediacion del N1. No se ejecuta texto: se valida y se usa el SDK."""
    comando = cuerpo.get("comando")
    version = validar_rollback(comando)
    publicadas = [v["Version"] for p in lam.get_paginator("list_versions_by_function").paginate(FunctionName=APP)
                  for v in p.get("Versions", []) if v["Version"] != "$LATEST"]
    if version not in publicadas:
        raise ErrorApi(400, f"La version {version} de {APP} no existe. Publicadas: {', '.join(publicadas[-8:])}.")
    antes = _live()
    lam.update_alias(FunctionName=APP, Name="live", FunctionVersion=version)
    movido = time.monotonic()
    aprobado = _ahora_ms()
    trafico = _trafico(VERIFICACIONES, movido)
    _olvidar_estado()
    return {"aprobado_ms": aprobado, "comando": comando.strip(), "version_antes": antes,
            "version_nueva": version, "es_estable": version == ESTABLE, "estable": ESTABLE,
            "db_host": _version(version)["db_host"], "invocaciones": VERIFICACIONES, **trafico}


def restaurar():
    """restaurar.sh: live a la version estable, DB_HOST=localhost en $LATEST y prueba de humo."""
    if not ESTABLE:
        raise ErrorApi(500, "La consola no conoce la version estable (variable STABLE_VERSION).")
    antes = _live()
    lam.update_alias(FunctionName=APP, Name="live", FunctionVersion=ESTABLE)
    movido = time.monotonic()
    _cambiar_db_host("localhost")
    humo = _trafico(1, movido)
    _olvidar_estado()
    return {"version_antes": antes, "live": ESTABLE, "humo": "OK" if humo["ok"] else "FALLA",
            "atendidas_por": humo["atendidas_por"], "alarma": _alarma()["estado"],
            "siguiente": "La alarma no se fuerza a OK: vuelve sola en cuanto evalua un minuto sin "
                         "errores (normalmente de 1 a 3 min)."}


# ─────────────────────────────────────────────────────────────
# Enrutado (HTTP API, payload 2.0)
# ─────────────────────────────────────────────────────────────
def _desde(event):
    valor = (event.get("queryStringParameters") or {}).get("desde")
    ahora = _ahora_ms()
    if valor in (None, ""):
        return ahora - VENTANA_MIN * 60 * 1000
    if not re.fullmatch(r"[0-9]{13}", valor):
        raise ErrorApi(400, "desde tiene que ser un instante en milisegundos (13 cifras).")
    desde = int(valor)
    if desde > ahora + 60_000 or desde < ahora - 24 * 3600 * 1000:
        raise ErrorApi(400, "desde tiene que estar dentro de las ultimas 24 horas.")
    return desde


RUTAS = {
    ("GET", "/api/estado"): (False, lambda ev: estado()),
    ("GET", "/api/diagnostico"): (False, lambda ev: diagnostico(_desde(ev))),
    ("POST", "/api/provocar"): (True, lambda ev: provocar()),
    ("POST", "/api/simular"): (True, lambda ev: simular()),
    ("POST", "/api/aprobar"): (True, lambda ev: aprobar(_cuerpo(ev))),
    ("POST", "/api/restaurar"): (True, lambda ev: restaurar()),
}
_THROTTLING = {"ThrottlingException", "TooManyRequestsException", "Throttling", "RequestLimitExceeded"}


def handler(event, context):
    global _CUENTA
    if not _CUENTA and context is not None:
        _CUENTA = context.invoked_function_arn.split(":")[4]
    metodo = ((event.get("requestContext") or {}).get("http") or {}).get("method", "")
    ruta = event.get("rawPath", "")
    t0 = time.time()
    try:
        if (metodo, ruta) not in RUTAS:
            if any(r == ruta for _, r in RUTAS):
                raise ErrorApi(405, f"{ruta} no admite {metodo}.")
            raise ErrorApi(404, f"No existe {ruta}.")
        pide_pin, accion = RUTAS[(metodo, ruta)]
        if pide_pin:
            _exigir_pin(event)
        codigo, cuerpo = 200, accion(event)
    except ErrorApi as e:
        codigo, cuerpo = e.codigo, {"error": e.mensaje, **e.extra}
    except WaiterError:
        codigo, cuerpo = 500, {"error": f"{APP} no termino de actualizarse a tiempo. Reintenta en unos segundos."}
    except ClientError as e:
        error = e.response.get("Error", {}).get("Code", "")
        print(f"[web] ERROR AWS en {metodo} {ruta}: {e}")       # el detalle va al log, no a la pantalla
        if error in _THROTTLING:
            codigo, cuerpo = 503, {"error": "AWS esta limitando las llamadas. Reintenta en unos segundos."}
        elif error in ("AccessDeniedException", "AccessDenied"):
            codigo, cuerpo = 500, {"error": f"La consola no tiene permiso para {e.operation_name}. "
                                            "Revisa la politica ManosDelHumano de su rol."}
        elif error == "ResourceNotFoundException":
            codigo, cuerpo = 404, {"error": "No encontre un recurso de la demo. Se borro o tiene otro nombre?"}
        else:
            codigo, cuerpo = 500, {"error": f"AWS respondio {error} en {e.operation_name}."}
    except Exception:  # noqa: BLE001 — la traza al log; a la pantalla, un mensaje claro
        print(f"[web] ERROR inesperado en {metodo} {ruta}:\n{traceback.format_exc()}")
        codigo, cuerpo = 500, {"error": "Error interno de la consola. El detalle quedo en su log."}
    print(f"[web] {metodo} {ruta} -> {codigo} en {round((time.time() - t0) * 1000)} ms")
    return _respuesta(codigo, cuerpo)
