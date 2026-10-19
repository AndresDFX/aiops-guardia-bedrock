/*
 * Consola de Guardia N1.
 * La página y la API viven en el mismo dominio de CloudFront: /api/... es una ruta
 * relativa, sin CORS y sin URLs que reemplazar al desplegar.
 * Todo lo que llega de la API (y el diagnóstico lo escribió un modelo que lee logs)
 * se pinta con textContent: nunca como HTML. Los enlaces solo se pintan si van a la
 * consola de AWS.
 */
"use strict";

// Cada consulta pasa por CloudFront, el HTTP API y una Lambda, y se cobra por petición.
// Rápido solo cuando hay algo que mirar; con la pestaña oculta, ninguna.
const SONDEO_INCIDENTE_MS = 3000;       // producción rota, alarma en ALARM o esperando el diagnóstico
const SONDEO_REPOSO_MS = 15000;         // todo en calma
const FALLOS_PARA_FRENAR = 5;           // con la API caída, tras 5 fallos seguidos se reintenta cada 15 s
const ESPERA_MAX_MS = 10 * 60 * 1000;   // sin diagnóstico en 10 min, se deja de esperar
const CLAVE_PIN = "guardia-pin";
const CLAVE_INCIDENTE = "guardia-incidente";
// Precio de Claude Sonnet 4.6 por el perfil us. (oct-2026, USD por millón de tokens):
// solo para estimar lo que costó cada diagnóstico.
const PRECIO_SONNET_46 = { entrada: 3.30, salida: 16.50 };

const $ = (id) => document.getElementById(id);

let estado = null;          // última respuesta de /api/estado
let incidente = leerIncidente();
let desfase = 0;            // reloj del servidor menos reloj local
let ocupado = false;        // hay una acción en curso
let enCiclo = false;
let temporizador = 0;       // el próximo sondeo programado (solo hay uno)
let fallos = 0;             // fallos seguidos al pedir el estado
let firmaDx = "";
let vista = "dx";           // pestaña del diagnóstico: dx, contexto o json
let accionEnCurso = "";

// ── Utilidades ──────────────────────────────────────────────
function el(etiqueta, props = {}, ...hijos) {
  const e = document.createElement(etiqueta);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else if (k === "onclick") e.addEventListener("click", v);
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const h of hijos) if (h != null && h !== false) e.append(h);
  return e;
}

// Solo enlaces a la consola de AWS de la región: el resto no se pinta.
function urlAws(url) {
  return typeof url === "string" && /^https:\/\/[a-z0-9-]+\.console\.aws\.amazon\.com\//.test(url) ? url : null;
}

function enlaceAws(texto, url, clase = "enlace-aws") {
  const u = urlAws(url);
  if (!u) return null;
  return el("a", { class: clase, href: u, target: "_blank", rel: "noopener noreferrer", title: "Abrir en la consola de AWS" }, `↗ ${texto}`);
}

function enlaces() { return (estado && estado.enlaces) || {}; }
function nombres() { return (estado && estado.nombres) || {}; }

function enlaceVersion(v) {
  const plantilla = enlaces().app_version;
  return plantilla && v ? plantilla.replace("{v}", encodeURIComponent(v)) : null;
}

function hora(ms) {
  return new Date(ms).toLocaleTimeString("es-CO", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
}

function duracion(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  const r = s % 60;
  return r ? `${m} min ${r} s` : `${m} min`;
}

function numero(n, decimales = 0) {
  return Number(n).toLocaleString("es-CO", { minimumFractionDigits: decimales, maximumFractionDigits: decimales });
}

function ahora() { return Date.now() + desfase; }

function leerIncidente() {
  try { return JSON.parse(sessionStorage.getItem(CLAVE_INCIDENTE)) || null; } catch { return null; }
}

function guardarIncidente() {
  try {
    if (incidente) sessionStorage.setItem(CLAVE_INCIDENTE, JSON.stringify(incidente));
    else sessionStorage.removeItem(CLAVE_INCIDENTE);
  } catch { /* sin almacenamiento: la pestaña sigue funcionando, solo no lo recuerda */ }
}

function nombreModelo(id) {
  const m = /claude-([a-z]+)-(\d+)-(\d+)/.exec(id || "");
  if (!m) return id || "el modelo";
  return `Claude ${m[1].charAt(0).toUpperCase()}${m[1].slice(1)} ${m[2]}.${m[3]}`;
}

function costoUsd(b, modelo) {
  if (!b || b.inputTokens == null || !/claude-sonnet-4-6/.test(modelo || "")) return null;
  return (b.inputTokens * PRECIO_SONNET_46.entrada + (b.outputTokens || 0) * PRECIO_SONNET_46.salida) / 1e6;
}

// "todas las atendió la v25", o el reparto si el alias todavía no había llegado a todas partes.
function atendidas(d) {
  const a = d.atendidas_por || {};
  const versiones = Object.keys(a);
  if (!versiones.length) return "";
  if (versiones.length === 1) return `, todas atendidas por la v${versiones[0]}`;
  return ` (${versiones.map((v) => `${a[v]} por la v${v}`).join(", ")})`;
}

// La consola muestra hora local; el N1 escribe en UTC, como los logs y CloudTrail.
function zonaLocal() {
  const minutos = -new Date().getTimezoneOffset();
  if (!minutos) return "UTC";
  const h = Math.trunc(Math.abs(minutos) / 60);
  const m = Math.abs(minutos) % 60;
  return `UTC${minutos > 0 ? "+" : "-"}${h}${m ? `:${String(m).padStart(2, "0")}` : ""}`;
}

function versionDelComando(cmd) {
  const m = /--function-version(?:=|\s+)(\d+)/.exec(cmd || "");
  return m ? String(Number(m[1])) : null;
}

async function pedir(ruta, opciones = {}) {
  const r = await fetch(ruta, { cache: "no-store", ...opciones });
  let datos = {};
  try { datos = await r.json(); } catch { datos = {}; }
  return { r, datos };
}

// ── Sondeo ──────────────────────────────────────────────────
function visible() { return document.visibilityState === "visible"; }

// Incidente: producción rota, la alarma sonando, una acción en curso o el diagnóstico del N1
// por llegar (como mucho ESPERA_MAX_MS). Antes del primer estado, también: que llegue pronto.
function enIncidente() {
  if (ocupado || !estado) return true;
  if (estado.produccion.salud === "rota" || estado.alarma.estado === "ALARM") return true;
  return Boolean(incidente && !incidente.diagnostico && !incidente.sin_dx);
}

function intervalo() {
  if (fallos >= FALLOS_PARA_FRENAR) return SONDEO_REPOSO_MS;
  return enIncidente() ? SONDEO_INCIDENTE_MS : SONDEO_REPOSO_MS;
}

// Un solo sondeo programado a la vez, y ninguno con la pestaña oculta.
function programar() {
  clearTimeout(temporizador);
  temporizador = 0;
  if (visible()) temporizador = setTimeout(ciclo, intervalo());
}

async function ciclo() {
  if (enCiclo) return;
  clearTimeout(temporizador);
  if (!visible()) return;           // oculta: no se pregunta nada; al volver se refresca
  enCiclo = true;
  try {
    const { r, datos } = await pedir("/api/estado");
    if (!r.ok) throw new Error(datos.error || `la API respondió HTTP ${r.status}`);
    desfase = datos.ahora_ms - Date.now();
    estado = datos;
    seguirIncidente();
    // Antes de la alarma no puede haber diagnóstico: el N1 lo despierta la alarma.
    if (incidente && !incidente.diagnostico && !incidente.sin_dx) {
      if (Date.now() - (incidente.creado || Date.now()) > ESPERA_MAX_MS) {
        incidente.sin_dx = true;
        guardarIncidente();
      } else if (incidente.alarma_ms) {
        await buscarDiagnostico();
      }
    }
    fallos = 0;
    conexion(true);
  } catch (e) {
    fallos += 1;
    conexion(false, e.message);
  } finally {
    enCiclo = false;
    pintar();
    programar();
  }
}

function incidenteDetectado() {
  const a = estado.alarma;
  const p = estado.produccion;
  const nuevo = { tipo: "detectado", desde: a.desde_ms - 1000, creado: Date.now(), alarma_ms: a.desde_ms };
  if (p.salud !== "sana" && p.live_publicada_ms) {
    nuevo.despliegue_ms = p.live_publicada_ms;
    nuevo.version_rota = p.live;
  }
  return nuevo;
}

function nuevoIncidente(datos) {
  incidente = datos;
  vista = "dx";
  guardarIncidente();
}

// Las horas del incidente salen del servidor: de la alarma, del log del N1 y de las acciones.
function seguirIncidente() {
  const a = estado.alarma;
  if (a.estado !== "ALARM") return;
  if (!incidente) {
    nuevoIncidente(incidenteDetectado());     // la alarma la disparó otro: la terminal u otra pestaña
  } else if (!incidente.alarma_ms) {
    if (a.desde_ms >= incidente.desde - 2000) incidente.alarma_ms = a.desde_ms;
  } else if (a.desde_ms > incidente.alarma_ms + 1000 && incidente.diagnostico) {
    nuevoIncidente(incidenteDetectado());     // volvió a sonar después de este incidente
  }
  guardarIncidente();
}

// Mientras Bedrock piensa, la traza ya dice qué pasó: cuándo despertó el N1 y qué contexto juntó.
async function buscarDiagnostico() {
  const { r, datos } = await pedir(`/api/diagnostico?desde=${Math.round(incidente.desde)}`);
  if (!r.ok) throw new Error(datos.error || `la API respondió HTTP ${r.status}`);
  if (datos.traza) incidente.traza = datos.traza;
  if (datos.contexto) incidente.contexto = datos.contexto;
  if (datos.enlaces) incidente.enlaces = datos.enlaces;
  if (datos.listo) {
    incidente.diagnostico = datos.resultado;
    incidente.diagnostico_ms = datos.hora_ms;
    incidente.fallo_n1 = null;
  } else {
    incidente.fallo_n1 = datos.fallo_n1 || null;
  }
  guardarIncidente();
}

function conexion(bien, detalle = "") {
  const c = $("conexion");
  c.classList.toggle("vivo", bien);
  c.classList.toggle("caida", !bien);
  $("conexion-texto").textContent = bien
    ? `En vivo · ${hora(ahora())}`
    : `Sin conexión: ${detalle}. Reintento en ${intervalo() / 1000} s`;
}

// ── Acciones ────────────────────────────────────────────────
function pedirPin(error = "") {
  return new Promise((resolver) => {
    const dialogo = $("d-pin");
    const entrada = $("i-pin");
    $("pin-error").textContent = error;
    entrada.value = "";
    const terminar = (valor) => {
      $("f-pin").onsubmit = null;
      $("pin-cancelar").onclick = null;
      dialogo.oncancel = null;
      if (dialogo.open) dialogo.close();
      resolver(valor);
    };
    $("f-pin").onsubmit = (ev) => {
      ev.preventDefault();
      const pin = entrada.value.trim();
      if (!pin) { $("pin-error").textContent = "Escribe el PIN."; return; }
      sessionStorage.setItem(CLAVE_PIN, pin);
      terminar(pin);
    };
    $("pin-cancelar").onclick = () => terminar(null);
    dialogo.oncancel = (ev) => { ev.preventDefault(); terminar(null); };
    dialogo.showModal();
    entrada.focus();
  });
}

const EN_CURSO = {
  provocar: "Desplegando la versión rota y mandando 12 peticiones…",
  simular: "Forzando la alarma…",
  aprobar: "Ejecutando el rollback aprobado y probando live…",
  restaurar: "Restaurando: live a la versión estable y DB_HOST=localhost…",
};

function resultado(clase, texto) {
  const r = $("resultado");
  r.className = `resultado ${clase}`;
  r.textContent = texto;
}

async function enviar(accion, cuerpo, pin) {
  return pedir(`/api/${accion}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Pin": pin },
    body: JSON.stringify(cuerpo || {}),
  });
}

async function accion(nombre, cuerpo) {
  if (ocupado) return;
  let pin = sessionStorage.getItem(CLAVE_PIN);
  if (!pin) {
    pin = await pedirPin();
    if (!pin) return;
  }
  ocupado = true;
  accionEnCurso = nombre;
  pintar();
  resultado("en-curso", EN_CURSO[nombre]);
  try {
    let { r, datos } = await enviar(nombre, cuerpo, pin);
    if (r.status === 401) {
      sessionStorage.removeItem(CLAVE_PIN);
      pin = await pedirPin(datos.error || "PIN incorrecto.");
      if (!pin) { resultado("aviso", "Acción cancelada: falta el PIN."); return; }
      resultado("en-curso", EN_CURSO[nombre]);
      ({ r, datos } = await enviar(nombre, cuerpo, pin));
    }
    if (r.status === 401) sessionStorage.removeItem(CLAVE_PIN);
    if (!r.ok) {
      resultado(r.status === 409 ? "aviso" : "error", datos.error || `La API respondió HTTP ${r.status}.`);
      return;
    }
    DESPUES[nombre](datos);
  } catch (e) {
    resultado("error", `No pude hablar con la API: ${e.message}`);
  } finally {
    ocupado = false;
    accionEnCurso = "";
    firmaDx = "";
    pintar();
    ciclo();
  }
}

const DESPUES = {
  provocar(d) {
    nuevoIncidente({
      tipo: "fallo", desde: d.desde, creado: Date.now(), despliegue_ms: d.despliegue_ms,
      version_rota: d.version_nueva, version_antes: d.version_antes, db_host: d.db_host, trafico: d.trafico,
      errores: d.errores, peticiones: d.peticiones,
    });
    resultado("ok", `Mal despliegue hecho: live pasó de v${d.version_antes} a v${d.version_nueva} y ` +
      `${d.errores} de ${d.peticiones} peticiones fallaron. La alarma tarda de 30 s a 2 min.`);
  },
  simular(d) {
    nuevoIncidente({ tipo: "simulada", desde: d.desde, creado: Date.now(), motivo: d.motivo });
    resultado("ok", "Alarma forzada a ALARM sin errores nuevos. El diagnóstico llega en 10 a 30 s.");
  },
  aprobar(d) {
    if (incidente) {
      incidente.aprobado_ms = d.aprobado_ms;
      incidente.aprobacion = d;
      guardarIncidente();
    }
    const bien = d.errores === 0;
    resultado(bien ? "ok" : "error", `Rollback aprobado: live pasó de v${d.version_antes} a v${d.version_nueva}. ` +
      `${d.ok} de ${d.invocaciones} invocaciones sin error${atendidas(d)}.`);
  },
  restaurar(d) {
    if (incidente) {
      incidente.restaurado_ms = ahora();
      guardarIncidente();
    }
    resultado(d.humo === "OK" ? "ok" : "error", `Restaurado: live en v${d.live} y DB_HOST=localhost. ` +
      `Prueba de humo: ${d.humo}. La alarma vuelve sola a OK en un minuto y medio, más o menos.`);
  },
};

// ── Pintar ──────────────────────────────────────────────────
function pintar() {
  pintarProduccion();
  pintarAlarma();
  pintarBotones();
  pintarRecorrido();
  pintarSiguiente();
  pintarDiagnostico();
}

function insignia(id, texto, color, latido = false) {
  const e = $(id);
  e.textContent = texto;
  e.className = `insignia ${color}${latido ? " latido" : ""}`;
}

function ponerEnlace(id, url) {
  const a = $(id);
  const u = urlAws(url);
  a.hidden = !u;
  if (u) a.href = u; else a.removeAttribute("href");
}

function pintarProduccion() {
  if (!estado) return;
  const p = estado.produccion;
  $("prod-funcion").textContent = `${p.funcion}:live`;
  ponerEnlace("prod-enlace", enlaces().app_alias);
  if (p.salud === "sana") {
    insignia("prod-insignia", "SANA", "verde");
    $("prod-texto").textContent = "live está en la versión estable";
  } else if (p.salud === "rota") {
    insignia("prod-insignia", "ROTA", "rojo", true);
    $("prod-texto").textContent = "live salió de la versión estable";
  } else {
    insignia("prod-insignia", "OTRA VERSIÓN", "ambar");
    $("prod-texto").textContent = "live no está en la versión estable";
  }
  for (const [id, v] of [["prod-live", p.live], ["prod-estable", p.estable]]) {
    const a = $(id);
    a.textContent = `v${v}`;
    const u = urlAws(enlaceVersion(v));
    if (u) { a.href = u; a.title = `Ver la v${v} en la consola de AWS`; } else a.removeAttribute("href");
  }
  $("prod-live-desc").textContent = p.live_descripcion;
  $("prod-estable-desc").textContent = p.estable_descripcion;
  $("caja-live").className = `version ${p.salud === "sana" ? "bien" : "mal"}`;
  const db = $("prod-dbhost");
  db.textContent = p.live_db_host || "(sin DB_HOST)";
  db.className = p.live_db_host === p.estable_db_host ? "" : "mal";
  pintarGrafico(estado.metricas || []);
}

function pintarGrafico(puntos) {
  const g = $("prod-grafico");
  g.replaceChildren();
  const maximo = Math.max(1, ...puntos.map((x) => x.invocaciones));
  let errores = 0;
  let invocaciones = 0;
  for (const x of puntos) {
    errores += x.errores;
    invocaciones += x.invocaciones;
    const bien = Math.max(0, x.invocaciones - x.errores);
    const barra = el("div", { class: "barra-min", title: `${hora(x.ms)}: ${x.invocaciones} invocaciones, ${x.errores} con error` });
    if (bien) barra.append(el("div", { class: "ok", style: `height:${(bien / maximo) * 100}%` }));
    if (x.errores) {
      barra.append(el("div", { class: "err", style: `height:${(x.errores / maximo) * 100}%` }));
      barra.append(el("span", { class: "cifra", style: `bottom:calc(${(x.invocaciones / maximo) * 100}% + 2px)`, text: String(x.errores) }));
    }
    g.append(barra);
  }
  const ejes = $("prod-ejes");
  ejes.replaceChildren();
  if (puntos.length) {
    ejes.append(el("span", { text: hora(puntos[0].ms).slice(0, 5) }),
      el("span", { text: "errores por minuto" }),
      el("span", { text: hora(puntos[puntos.length - 1].ms).slice(0, 5) }));
  }
  const cuenta = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`;
  $("prod-nota").textContent = invocaciones
    ? `${cuenta(errores, "error", "errores")} en ${cuenta(invocaciones, "invocación", "invocaciones")} (10 min, con 1-2 min de retraso).`
    : "Sin tráfico en 10 min (la métrica llega con 1-2 min de retraso).";
}

function pintarAlarma() {
  if (!estado) return;
  const a = estado.alarma;
  $("alarma-nombre").textContent = a.nombre;
  ponerEnlace("alarma-enlace", enlaces().alarma);
  if (a.estado === "ALARM") insignia("alarma-insignia", "ALARM", "rojo", true);
  else if (a.estado === "OK") insignia("alarma-insignia", "OK", "verde");
  else insignia("alarma-insignia", "SIN DATOS", "gris");
  $("alarma-hora").textContent = `Desde las ${hora(a.desde_ms)} · hace ${duracion(ahora() - a.desde_ms)}`;
  const m = $("alarma-motivo");
  m.textContent = a.motivo;
  m.title = a.motivo;
}

function bloqueoDeBotones() {
  if (!estado) return "Esperando el estado de la API…";
  if (estado.alarma.estado === "ALARM") return "Para romper o simular, espera a que la alarma vuelva a OK.";
  if (estado.produccion.salud !== "sana") return `live está en v${estado.produccion.live}: aprueba el rollback o restaura.`;
  return "";
}

function pintarBotones() {
  const hayPin = Boolean(sessionStorage.getItem(CLAVE_PIN));
  const pe = $("pin-estado");
  pe.textContent = hayPin ? "PIN guardado en esta pestaña" : "Piden el PIN";
  pe.className = `pide-pin${hayPin ? " guardado" : ""}`;

  // Romper o simular solo tiene sentido con producción sana y la alarma fuera de ALARM:
  // EventBridge avisa cuando la alarma CAMBIA de estado, no mientras sigue en ALARM.
  const bloqueo = bloqueoDeBotones();
  const aviso = $("a-bloqueo");
  aviso.textContent = bloqueo;
  aviso.hidden = !bloqueo;
  $("b-provocar").disabled = ocupado || Boolean(bloqueo);
  $("b-simular").disabled = ocupado || Boolean(bloqueo);
  $("b-restaurar").disabled = ocupado;
}

// ── El recorrido: cada pieza de AWS que toca el incidente, en orden ─────────
function dxActual() {
  return incidente && incidente.diagnostico ? incidente.diagnostico.diagnostico || {} : null;
}

function esFalsaAlarma(d) {
  return Boolean(d && (d.posible_falsa_alarma || !d.comando_remediacion));
}

function resumenContexto(ctx) {
  if (!ctx) return "";
  const partes = [];
  const errores = (ctx.errores_en_logs || []).filter((x) => /^\d+x /.test(String(x)));
  const versiones = ((ctx.despliegue || {}).versiones_publicadas || []).length;
  const cambios = (ctx.cambios_cloudtrail || []).filter((x) => x && typeof x === "object").length;
  partes.push(`${errores.length} ${errores.length === 1 ? "error agrupado" : "errores agrupados"}`);
  if (versiones) partes.push(`${versiones} versiones`);
  partes.push(`${cambios} ${cambios === 1 ? "cambio" : "cambios"} en CloudTrail`);
  return partes.join(", ");
}

function nodosDelRecorrido() {
  const i = incidente;
  const L = enlaces();
  const N = nombres();
  const t = (i && i.traza) || {};
  const r = i && i.diagnostico;
  const d = dxActual();
  const b = r ? r.bedrock || {} : null;
  const p = estado && estado.produccion;
  const nodos = [];

  // 1. La app de pagos
  const app = { clave: "app", titulo: "App de pagos", servicio: "Lambda", recurso: `${N.app || "guardia-app-pagos"}:live`,
    enlaces: [["Versiones", L.app_versiones], ["CloudTrail", L.app_cloudtrail]] };
  if (!i) {
    Object.assign(app, p ? { estado: p.salud === "sana" ? "espera" : "mal", detalle: `live en v${p.live}${p.salud === "sana" ? " (la estable)" : ", fuera de la estable"}` }
      : { estado: "espera", detalle: "Leyendo producción…" });
  } else if (i.tipo === "simulada") {
    Object.assign(app, { estado: "neutro", detalle: "Sin cambios: la alarma se forzó a mano" });
  } else if (i.version_rota) {
    Object.assign(app, { estado: "mal", ms: i.despliegue_ms, detalle: `Mal despliegue: live → v${i.version_rota}` +
      (i.peticiones ? ` · ${i.errores} de ${i.peticiones} peticiones fallan` : "") });
  } else {
    Object.assign(app, { estado: "neutro", detalle: "La alarma la disparó otra terminal o pestaña" });
  }
  nodos.push(app);

  // 2. La alarma
  const alarma = { clave: "alarma", titulo: "Alarma", servicio: "CloudWatch", recurso: N.alarma || "guardia-app-pagos-errores",
    enlaces: [["Alarma", L.alarma]] };
  if (i && i.alarma_ms) {
    Object.assign(alarma, { estado: "mal", ms: i.alarma_ms,
      detalle: i.tipo === "simulada" ? "ALARM forzada con set-alarm-state" : "ALARM: 3 o más errores en un minuto" });
  } else if (i) {
    Object.assign(alarma, { estado: "activo", detalle: "Esperando ALARM: la métrica es por minuto (30 s a 2 min)" });
  } else {
    Object.assign(alarma, { estado: "espera", detalle: estado ? `En ${estado.alarma.estado}. Salta con 3 o más errores en un minuto` : "" });
  }
  nodos.push(alarma);

  // 3. EventBridge
  const regla = { clave: "regla", titulo: "Regla", servicio: "EventBridge", recurso: N.regla || "guardia-alarma-a-oncall",
    enlaces: [["Regla", L.regla]] };
  if (t.n1_inicio_ms) Object.assign(regla, { estado: "hecho", ms: t.n1_inicio_ms, detalle: "Llevó el cambio a ALARM a la Lambda del N1" });
  else if (i && i.alarma_ms && !r) Object.assign(regla, { estado: "activo", detalle: "Entregando el evento al N1…" });
  else Object.assign(regla, { estado: "espera", detalle: "Escucha las alarmas guardia-* que pasan a ALARM" });
  nodos.push(regla);

  // 4. El N1 junta el contexto
  const n1 = { clave: "n1", titulo: "Ingeniero N1", servicio: "Lambda · solo lectura", recurso: N.oncall || "guardia-oncall",
    enlaces: [["Logs", (i && i.enlaces && i.enlaces.invocacion) || L.oncall_logs]],
    accion: i && i.contexto ? ["Ver contexto", () => cambiarVista("contexto")] : null };
  if (t.contexto_ms) {
    Object.assign(n1, { estado: "hecho", ms: t.contexto_ms,
      detalle: `Contexto en ${numero(t.contexto_s, 1)} s: ${resumenContexto(i.contexto) || `${numero(t.contexto_caracteres)} caracteres`}` });
  } else if (t.n1_inicio_ms) {
    Object.assign(n1, { estado: "activo", detalle: "Juntando métricas, logs, versiones y CloudTrail…" });
  } else {
    Object.assign(n1, { estado: "espera", detalle: "Junta métricas, logs, versiones y cambios en un segundo" });
  }
  nodos.push(n1);

  // 5. Bedrock
  const modelo = (r && r.modelo) || N.modelo || "us.anthropic.claude-sonnet-4-6";
  const ia = { clave: "ia", titulo: "Bedrock", servicio: `${nombreModelo(modelo)} · Converse`,
    recurso: /^us\./.test(modelo) ? "perfil us. (entre regiones)" : modelo, enlaces: [["Modelo", L.bedrock]] };
  if (b && b.latencia_s != null) {
    const c = costoUsd(b, modelo);
    Object.assign(ia, { estado: "hecho", ms: t.bedrock_ms || (i && i.diagnostico_ms),
      detalle: `Respondió en ${numero(b.latencia_s, 1)} s · ${numero(b.inputTokens)} + ${numero(b.outputTokens)} tokens` +
        (c != null ? ` · ≈ USD ${numero(c, 3)}` : "") });
  } else if (t.contexto_ms) {
    Object.assign(ia, { estado: "activo", detalle: "Leyendo el contexto y escribiendo el diagnóstico (6 a 9 s)…" });
  } else {
    Object.assign(ia, { estado: "espera", detalle: "Responde un JSON con la causa raíz y un comando" });
  }
  nodos.push(ia);

  // 6. El diagnóstico publicado
  const dx = { clave: "dx", titulo: "Diagnóstico", servicio: "CloudWatch Logs · SNS", recurso: "DIAGNOSTICO_JSON",
    enlaces: [["Log", (i && i.enlaces && i.enlaces.invocacion) || L.oncall_logs], ["SNS", L.sns]] };
  if (d) {
    Object.assign(dx, { estado: "hecho", ms: i.diagnostico_ms, sev: d.severidad,
      detalle: `${d.severidad || "SEV?"}${d.posible_falsa_alarma ? " · posible falsa alarma" : ""}` +
        `${t.sns_ms ? " · publicado en SNS" : " · publicado"}` });
  } else if (i && i.fallo_n1) {
    Object.assign(dx, { estado: "mal", detalle: "El N1 falló al llamar a Bedrock: mira sus logs" });
  } else if (i && i.sin_dx) {
    Object.assign(dx, { estado: "mal", detalle: "Sin diagnóstico en 10 min: mira la alarma y los logs" });
  } else if (b) {
    Object.assign(dx, { estado: "activo", detalle: "Publicando…" });
  } else {
    Object.assign(dx, { estado: "espera", detalle: "Severidad, causa raíz y propuesta, en logs y por correo" });
  }
  nodos.push(dx);

  // 7. La persona decide
  const tu = { clave: "tu", titulo: "Tú decides", servicio: "Consola · Lambda propia", recurso: N.consola || "guardia-web",
    enlaces: [["Alias live", L.app_alias]] };
  if (i && i.aprobacion) {
    const ap = i.aprobacion;
    Object.assign(tu, { estado: ap.errores === 0 ? "bien" : "mal", ms: i.aprobado_ms,
      detalle: `update-alias: live → v${ap.version_nueva} · ${ap.ok} de ${ap.invocaciones} sin error` });
  } else if (d && esFalsaAlarma(d)) {
    Object.assign(tu, { estado: "neutro", detalle: "Nada que aprobar: el N1 no propone cambios" });
  } else if (d) {
    Object.assign(tu, { estado: "activo", detalle: "Compara la versión con la estable y decide" });
  } else {
    Object.assign(tu, { estado: "espera", detalle: "Solo se ejecuta si apruebas, con el rol de la consola" });
  }
  nodos.push(tu);
  return nodos;
}

function pintarRecorrido() {
  const lista = $("nodos");
  lista.replaceChildren();
  const tipo = $("linea-tipo");
  tipo.className = "etiqueta";
  tipo.textContent = "";
  if (incidente) {
    const etiquetas = { fallo: "Mal despliegue", simulada: "Falsa alarma simulada", detectado: "Detectado por la alarma" };
    tipo.textContent = etiquetas[incidente.tipo] || "";
    tipo.classList.add(incidente.tipo === "simulada" ? "simulada" : "fallo");
  }
  let anterior = null;
  nodosDelRecorrido().forEach((n, k) => {
    let horaTexto = null;
    if (n.ms) {
      const delta = anterior && n.ms >= anterior ? el("span", { class: "delta", text: `+${duracion(n.ms - anterior)}` }) : null;
      horaTexto = el("div", { class: "nodo-hora" }, el("span", { text: hora(n.ms) }), delta);
      anterior = n.ms;
    }
    const links = el("div", { class: "nodo-enlaces" },
      ...n.enlaces.map(([texto, url]) => enlaceAws(texto, url)),
      n.accion ? el("button", { type: "button", class: "enlace-vista", onclick: n.accion[1] }, n.accion[0]) : null);
    lista.append(el("li", { class: `nodo ${n.estado} n-${n.clave}${n.sev ? ` ${n.sev}` : ""}` },
      el("div", { class: "nodo-cabeza" },
        el("span", { class: "nodo-num", text: String(k + 1) }),
        el("span", { class: "nodo-titulo", text: n.titulo })),
      el("div", { class: "nodo-servicio", title: `${n.servicio} · ${n.recurso}` }, `${n.servicio} · `, el("code", { text: n.recurso })),
      horaTexto,
      el("div", { class: "nodo-detalle", text: n.detalle || "" }),
      links));
  });
}

// ── Qué sigue: la consola le dice a quien la usa cuál es el próximo paso ─────
function siguientePaso() {
  if (!estado) return "Conectando con la demo…";
  if (ocupado) return EN_CURSO[accionEnCurso] || "Trabajando…";
  const i = incidente;
  const p = estado.produccion;
  const a = estado.alarma;
  const d = dxActual();
  if (i && !i.alarma_ms && !i.sin_dx) {
    return i.tipo === "simulada" ? "Forzando la alarma…" : "Espera la alarma: de 30 s a 2 min. Mientras, mira el recorrido.";
  }
  if (i && i.alarma_ms && !d) {
    if (i.fallo_n1 || i.sin_dx) return "El N1 no pudo diagnosticar: abre sus logs (paso 4) y pulsa Restaurar.";
    return "El N1 está trabajando: el diagnóstico llega en 10 a 30 s.";
  }
  if (i && d && !esFalsaAlarma(d) && !i.aprobacion) {
    const v = versionDelComando(d.comando_remediacion);
    if (v && p.estable && v !== p.estable) return `No apruebes: propone la v${v} y la estable es la v${p.estable}. Pulsa Restaurar.`;
    return `Propone la v${v || "?"}, que es la estable: revisa la causa y pulsa Aprobar.`;
  }
  if (i && i.aprobacion && !i.restaurado_ms) return "Rollback hecho. Pulsa Restaurar para dejar también la variable limpia.";
  if (i && d && esFalsaAlarma(d) && i.tipo === "simulada") {
    return a.estado === "ALARM" ? "SEV4 y nada que aprobar: no se inventó un incidente. La alarma vuelve sola a OK."
      : "SEV4 y nada que aprobar: no se inventó un incidente. Listo para repetir.";
  }
  if (a.estado === "ALARM") return "Espera a que la alarma vuelva sola a OK (hasta 1,5 min).";
  if (p.salud !== "sana") return "Producción no está en la estable: pulsa Restaurar.";
  if (i && i.aprobacion) return "Todo sano. Prueba Simular falsa alarma: ¿el N1 se da cuenta?";
  return "Pulsa Provocar mal despliegue para empezar.";
}

function pintarSiguiente() {
  const s = $("siguiente");
  const texto = siguientePaso();
  s.replaceChildren(el("span", { class: "siguiente-rotulo", text: "Siguiente paso" }), el("span", { text: texto }));
}

// ── Diagnóstico, contexto y JSON ────────────────────────────
function cambiarVista(nueva) {
  vista = nueva;
  firmaDx = "";
  pintarDiagnostico();
  $("t-diagnostico").scrollIntoView({ behavior: "smooth", block: "start" });
}

function pintarPestanas(hayDx) {
  const nav = $("pestanas");
  nav.hidden = !hayDx;
  for (const b of nav.querySelectorAll(".pestana")) {
    const activa = b.dataset.vista === vista;
    b.setAttribute("aria-selected", activa ? "true" : "false");
    b.classList.toggle("activa", activa);
    b.disabled = b.dataset.vista === "contexto" && !(incidente && incidente.contexto);
  }
}

function pintarDiagnostico() {
  const i = incidente;
  const firma = JSON.stringify([i && i.desde, i && i.diagnostico_ms, i && i.aprobado_ms, i && i.alarma_ms,
    i && i.fallo_n1, i && i.sin_dx, i && i.traza, Boolean(i && i.contexto), vista, ocupado,
    estado && estado.produccion.estable]);
  if (firma === firmaDx) return;
  firmaDx = firma;
  const caja = $("dx");
  caja.replaceChildren();
  if (vista !== "dx" && !(i && i.diagnostico)) vista = "dx";
  pintarPestanas(Boolean(i && i.diagnostico));

  if (!i) {
    caja.append(el("div", { class: "vacio" },
      el("p", { class: "grande", text: "Sin incidentes por ahora." }),
      el("p", { text: "Cuando la alarma pase a ALARM, EventBridge despierta al N1. Junta métricas, logs y despliegues, " +
        "se los pasa a Claude y deja aquí su propuesta. Su rol es de solo lectura: no puede ejecutar nada. " +
        "Arriba, el recorrido muestra cada pieza de AWS con su enlace a la consola." })));
    return;
  }

  if (!i.diagnostico) {
    if (i.fallo_n1) {
      caja.append(el("div", { class: "esperando fallo" },
        el("span", { text: `El N1 falló al llamar a Bedrock: ${i.fallo_n1}` })));
      return;
    }
    if (i.sin_dx) {
      caja.append(el("div", { class: "esperando fallo" },
        el("span", { text: "Pasaron 10 min sin diagnóstico. Revisa la alarma y los logs de guardia-oncall." })));
      return;
    }
    const t = i.traza || {};
    const texto = !i.alarma_ms
      ? (i.tipo === "simulada" ? "Forzando la alarma…" : "Esperando a que la alarma pase a ALARM. La métrica de Lambda es por minuto: tarda de 30 s a 2 min.")
      : t.contexto_ms ? `Contexto listo en ${numero(t.contexto_s, 1)} s. Claude está escribiendo el diagnóstico (6 a 9 s)…`
        : `La alarma sonó a las ${hora(i.alarma_ms)}. El N1 está leyendo métricas, logs y despliegues (10 a 30 s en total).`;
    caja.append(el("div", { class: "esperando" }, el("span", { class: "giro", "aria-hidden": "true" }), el("span", { text: texto })));
    return;
  }

  if (vista === "contexto") { pintarContexto(caja); return; }
  if (vista === "json") { pintarJson(caja); return; }

  const r = i.diagnostico;
  const d = r.diagnostico || {};
  const b = r.bedrock || {};
  const meta = [`${nombreModelo(r.modelo)} en Bedrock`];
  if (b.latencia_s != null) meta.push(`${numero(b.latencia_s, 1)} s`);
  if (b.inputTokens != null) meta.push(`${numero(b.inputTokens)} tokens de entrada y ${numero(b.outputTokens)} de salida`);
  const c = costoUsd(b, r.modelo);
  if (c != null) meta.push(`≈ USD ${numero(c, 3)}`);

  caja.append(el("div", { class: "dx-cabeza" },
    el("span", { class: `chip sev ${d.severidad || ""}`, text: d.severidad || "SEV?" }),
    el("span", { class: "chip", text: `Confianza ${d.confianza || "?"}` }),
    el("span", { class: `chip${d.posible_falsa_alarma ? " falsa" : ""}`, text: d.posible_falsa_alarma ? "Posible falsa alarma" : "Falsa alarma: no" }),
    el("span", { class: "dx-meta", text: `${meta.join(" · ")}\nListo a las ${hora(i.diagnostico_ms)}. ` +
      (zonaLocal() === "UTC" ? "Horas en UTC." : `El N1 escribe las horas en UTC; aquí es ${zonaLocal()}.`) })));
  caja.append(el("p", { class: "dx-resumen", text: d.resumen || "" }));
  caja.append(el("div", { class: "dx-bloque" }, el("h3", { text: "Causa raíz" }), el("p", { text: d.causa_raiz || "" })));
  // La decisión va antes que el detalle: en la sala, el botón tiene que verse sin bajar.
  caja.append(propuesta(d));
  if (Array.isArray(d.evidencia) && d.evidencia.length) {
    caja.append(el("div", { class: "dx-bloque" }, el("h3", { text: "Evidencia" }),
      el("ul", {}, ...d.evidencia.map((x) => el("li", { text: String(x) })))));
  }
  if (d.comando_verificacion) {
    caja.append(el("div", { class: "dx-bloque" }, el("h3", { text: "Para verificar" }),
      el("pre", { class: "comando claro", text: d.comando_verificacion })));
  }
  if (d.notas) caja.append(el("div", { class: "dx-bloque" }, el("h3", { text: "Notas para el siguiente nivel" }), el("p", { text: d.notas })));
  const log = enlaceAws("Ver esta invocación del N1 en CloudWatch Logs", i.enlaces && i.enlaces.invocacion, "enlace-aws grande");
  if (log) caja.append(el("p", { class: "dx-pie" }, log));
}

function propuesta(d) {
  const i = incidente;
  const ap = i.aprobacion;
  const caja = el("div", { class: `propuesta${ap ? " aprobada" : ""}` });
  const titulo = ap ? "Propuesta del N1 · aprobada y ejecutada"
    : d.comando_remediacion ? "Propuesta del N1 · todavía no se ejecutó" : "Propuesta del N1 · ningún cambio";
  caja.append(el("div", { class: "propuesta-titulo" },
    el("strong", { text: titulo }),
    el("span", { text: "El N1 tiene rol de solo lectura" })));

  if (!d.comando_remediacion) {
    caja.append(el("p", { class: "sin-propuesta", text: d.posible_falsa_alarma
      ? "El N1 no propone ningún cambio: las métricas no respaldan la alarma."
      : "El N1 no propone un comando. Revisa las notas." }));
    return caja;
  }
  caja.append(el("pre", { class: "comando", text: d.comando_remediacion }));
  if (d.riesgo_remediacion) caja.append(el("p", { class: "riesgo", text: `Riesgo: ${d.riesgo_remediacion}` }));

  const v = versionDelComando(d.comando_remediacion);
  const estable = estado && estado.produccion.estable;
  if (v && estable && !ap) {
    caja.append(v === estable
      ? el("p", { class: "alerta bien", text: `Propone volver a la v${v}, que es la versión estable.` })
      : el("p", { class: "alerta mal", text: `Ojo: propone volver a la v${v}, y la versión estable es la v${estable}.` }));
  }
  if (ap) {
    caja.append(el("p", { class: `alerta ${ap.errores === 0 ? "bien" : "mal"}`,
      text: `Aprobado a las ${hora(ap.aprobado_ms)}. live pasó de v${ap.version_antes} a v${ap.version_nueva}. ` +
        `${ap.ok} de ${ap.invocaciones} invocaciones sin error${atendidas(ap)}.` }));
    return caja;
  }
  const boton = el("button", { type: "button", class: "boton verde", text: "Aprobar y ejecutar rollback" });
  boton.disabled = ocupado;
  boton.addEventListener("click", () => accion("aprobar", { comando: d.comando_remediacion }));
  caja.append(el("div", { class: "decision" }, boton,
    el("p", { text: "Solo se ejecuta si es un update-alias de live en la app de pagos. Lo ejecuta la consola con su propio rol, no el N1." })));
  return caja;
}

// Lo que la Lambda del N1 le mandó a Claude, tal cual: el context engineering a la vista.
function seriesPorMinuto(metricas) {
  const filas = {};
  const columnas = [["Invocations.Sum", "Invocaciones"], ["Errors.Sum", "Errores"], ["Duration.Average", "Duración media (ms)"]];
  for (const [clave] of columnas) {
    for (const par of (metricas || {})[clave] || []) {
      const [minuto, valor] = String(par).split("=");
      (filas[minuto] = filas[minuto] || {})[clave] = valor;
    }
  }
  const minutos = Object.keys(filas).sort().slice(-8);
  return { columnas, minutos, filas };
}

function pintarContexto(caja) {
  const i = incidente;
  const ctx = i.contexto;
  const t = i.traza || {};
  if (!ctx) {
    caja.append(el("p", { class: "vacio-texto", text: "El contexto de esta invocación no está en el log (¿lo borró la retención de 1 día?)." }));
    return;
  }
  const N = nombres();
  caja.append(el("p", { class: "ctx-intro" },
    `Esto es lo que la Lambda ${N.oncall || "guardia-oncall"} le mandó a Claude, tal cual` +
    (t.contexto_s != null ? `: ${numero(t.contexto_caracteres || 0)} caracteres, juntados en ${numero(t.contexto_s, 1)} s. ` : ". ") +
    "Nada más: el modelo razona sobre esto. ",
    enlaceAws("Ver el CONTEXTO_JSON en CloudWatch Logs", i.enlaces && i.enlaces.invocacion)));

  const rejilla = el("div", { class: "ctx-rejilla" });
  const al = ctx.alarma || {};
  rejilla.append(seccion("La alarma", "CloudWatch",
    el("p", { class: "ctx-texto", text: al.motivo || "" }),
    el("p", { class: "ctx-suave", text: `${al.nombre || ""} · ${al.estado_anterior || "?"} → ${al.estado || "?"}` })));

  const s = seriesPorMinuto(ctx.metricas_por_minuto);
  if (s.minutos.length) {
    const tabla = el("table", { class: "ctx-tabla" },
      el("thead", {}, el("tr", {}, el("th", { text: "Minuto (UTC)" }), ...s.columnas.map(([, n]) => el("th", { text: n })))),
      el("tbody", {}, ...s.minutos.map((m) => el("tr", { class: Number(s.filas[m]["Errors.Sum"] || 0) > 0 ? "con-error" : "" },
        el("td", { text: m }), ...s.columnas.map(([c]) => el("td", { text: s.filas[m][c] != null ? String(Number(s.filas[m][c])) : "–" }))))));
    rejilla.append(seccion("Métricas por minuto", "CloudWatch · GetMetricData", tabla));
  }

  const errores = ctx.errores_en_logs || [];
  rejilla.append(seccion("Errores en los logs, agrupados", "CloudWatch Logs de la app",
    el("div", { class: "ctx-logs" }, ...errores.map((linea) => {
      const m = /^(\d+x) (.*)$/.exec(String(linea));
      return el("div", { class: "ctx-linea" }, m ? el("span", { class: "veces", text: m[1] }) : null, m ? ` ${m[2]}` : String(linea));
    }))));

  const dep = ctx.despliegue || {};
  const live = ((dep.aliases || []).find((a) => a.alias === "live") || {}).apunta_a_version;
  const estable = dep.ultima_version_buena_conocida;
  const versiones = dep.versiones_publicadas || [];
  if (versiones.length) {
    rejilla.append(seccion("Versiones que vio", "Lambda · ListVersionsByFunction",
      el("ul", { class: "ctx-versiones" }, ...versiones.map((v) => {
        const host = (v.variables || {}).DB_HOST || "";
        const etiquetas = [];
        if (v.version === live) etiquetas.push(el("span", { class: "tag live", text: "live" }));
        if (v.version === estable || v.marca) etiquetas.push(el("span", { class: "tag estable", text: "estable según el despliegue" }));
        const numeroV = urlAws(enlaceVersion(v.version))
          ? el("a", { class: "ctx-v", href: enlaceVersion(v.version), target: "_blank", rel: "noopener noreferrer", text: `v${v.version}` })
          : el("span", { class: "ctx-v", text: `v${v.version}` });
        return el("li", { class: host && host !== "localhost" ? "rota" : "" }, numeroV, ...etiquetas,
          el("span", { class: "ctx-desc", text: v.descripcion || "" }), el("code", { text: host ? `DB_HOST=${host}` : "" }));
      })),
      dep.aviso_version_estable ? el("p", { class: "ctx-suave", text: dep.aviso_version_estable }) : null));
  }

  const cambios = ctx.cambios_cloudtrail || [];
  rejilla.append(seccion("Cambios recientes", "CloudTrail · Event history",
    el("ul", { class: "ctx-cambios" }, ...cambios.slice(0, 6).map((c) => (c && typeof c === "object")
      ? el("li", {}, el("code", { text: (c.hora || "").replace("T", " ").replace("Z", "") }), ` ${c.evento || ""} `,
        el("span", { class: "ctx-suave", text: c.usuario ? `por ${c.usuario}` : "" }))
      : el("li", { class: "ctx-suave", text: String(c) })))));
  caja.append(rejilla);
}

function seccion(titulo, fuente, ...hijos) {
  return el("section", { class: "ctx-seccion" },
    el("h3", {}, el("span", { text: titulo }), el("span", { class: "ctx-fuente", text: fuente })), ...hijos);
}

function pintarJson(caja) {
  const i = incidente;
  caja.append(el("h3", { class: "json-titulo", text: "DIAGNOSTICO_JSON: lo que publicó el N1" }),
    el("pre", { class: "json", text: JSON.stringify(i.diagnostico, null, 2) }));
  if (i.contexto) {
    caja.append(el("h3", { class: "json-titulo", text: "CONTEXTO_JSON: lo que recibió Claude" }),
      el("pre", { class: "json", text: JSON.stringify(i.contexto, null, 2) }));
  }
}

// ── Arranque ────────────────────────────────────────────────
$("b-provocar").addEventListener("click", () => accion("provocar"));
$("b-simular").addEventListener("click", () => accion("simular"));
$("b-restaurar").addEventListener("click", () => accion("restaurar"));
for (const b of document.querySelectorAll("#pestanas .pestana")) {
  b.addEventListener("click", () => { vista = b.dataset.vista; firmaDx = ""; pintarDiagnostico(); });
}
// Oculta: se cancela el sondeo programado. Visible otra vez: refresco inmediato.
document.addEventListener("visibilitychange", () => { if (visible()) ciclo(); else programar(); });
pintar();
ciclo();
