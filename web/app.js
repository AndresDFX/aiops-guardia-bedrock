/*
 * Consola de Guardia N1.
 * La página y la API viven en el mismo dominio de CloudFront: /api/... es una ruta
 * relativa, sin CORS y sin URLs que reemplazar al desplegar.
 * Todo lo que llega de la API (y el diagnóstico lo escribió un modelo que lee logs)
 * se pinta con textContent: nunca como HTML.
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

const $ = (id) => document.getElementById(id);

let estado = null;          // última respuesta de /api/estado
let incidente = leerIncidente();
let desfase = 0;            // reloj del servidor menos reloj local
let ocupado = false;        // hay una acción en curso
let enCiclo = false;
let temporizador = 0;       // el próximo sondeo programado (solo hay uno)
let fallos = 0;             // fallos seguidos al pedir el estado
let firmaDx = "";

// ── Utilidades ──────────────────────────────────────────────
function el(etiqueta, props = {}, ...hijos) {
  const e = document.createElement(etiqueta);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const h of hijos) if (h != null && h !== false) e.append(h);
  return e;
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
  if (incidente) sessionStorage.setItem(CLAVE_INCIDENTE, JSON.stringify(incidente));
  else sessionStorage.removeItem(CLAVE_INCIDENTE);
}

function nombreModelo(id) {
  const m = /claude-([a-z]+)-(\d+)-(\d+)/.exec(id || "");
  if (!m) return id || "el modelo";
  return `Claude ${m[1].charAt(0).toUpperCase()}${m[1].slice(1)} ${m[2]}.${m[3]}`;
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
    if (incidente && !incidente.diagnostico && !incidente.sin_dx) await buscarDiagnostico();
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

// Las horas del incidente salen del servidor: de la alarma, del log del N1 y de las acciones.
function seguirIncidente() {
  const a = estado.alarma;
  if (a.estado !== "ALARM") return;
  if (!incidente) {
    incidente = incidenteDetectado();         // la alarma la disparó otro: la terminal u otra pestaña
  } else if (!incidente.alarma_ms) {
    if (a.desde_ms >= incidente.desde - 2000) incidente.alarma_ms = a.desde_ms;
  } else if (a.desde_ms > incidente.alarma_ms + 1000 && incidente.diagnostico) {
    incidente = incidenteDetectado();         // volvió a sonar después de este incidente
  }
  guardarIncidente();
}

async function buscarDiagnostico() {
  if (Date.now() - (incidente.creado || Date.now()) > ESPERA_MAX_MS) {
    incidente.sin_dx = true;
    guardarIncidente();
    return;
  }
  const { r, datos } = await pedir(`/api/diagnostico?desde=${Math.round(incidente.desde)}`);
  if (!r.ok) throw new Error(datos.error || `la API respondió HTTP ${r.status}`);
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
    firmaDx = "";
    pintar();
    ciclo();
  }
}

const DESPUES = {
  provocar(d) {
    incidente = {
      tipo: "fallo", desde: d.desde, creado: Date.now(), despliegue_ms: d.despliegue_ms,
      version_rota: d.version_nueva, version_antes: d.version_antes, db_host: d.db_host, trafico: d.trafico,
    };
    guardarIncidente();
    resultado("ok", `Mal despliegue hecho: live pasó de v${d.version_antes} a v${d.version_nueva} y ` +
      `${d.errores} de ${d.peticiones} peticiones fallaron. La alarma tarda de 1 a 3 min.`);
  },
  simular(d) {
    incidente = { tipo: "simulada", desde: d.desde, creado: Date.now(), motivo: d.motivo };
    guardarIncidente();
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
      `Prueba de humo: ${d.humo}. La alarma vuelve sola a OK en 1 a 3 min.`);
  },
};

// ── Pintar ──────────────────────────────────────────────────
function pintar() {
  pintarProduccion();
  pintarAlarma();
  pintarBotones();
  pintarLinea();
  pintarDiagnostico();
}

function insignia(id, texto, color, latido = false) {
  const e = $(id);
  e.textContent = texto;
  e.className = `insignia ${color}${latido ? " latido" : ""}`;
}

function pintarProduccion() {
  if (!estado) return;
  const p = estado.produccion;
  $("prod-funcion").textContent = `${p.funcion}:live`;
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
  $("prod-live").textContent = `v${p.live}`;
  $("prod-live-desc").textContent = p.live_descripcion;
  $("prod-estable").textContent = `v${p.estable}`;
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
  if (a.estado === "ALARM") insignia("alarma-insignia", "ALARM", "rojo", true);
  else if (a.estado === "OK") insignia("alarma-insignia", "OK", "verde");
  else insignia("alarma-insignia", "SIN DATOS", "gris");
  $("alarma-hora").textContent = `Desde las ${hora(a.desde_ms)} · hace ${duracion(ahora() - a.desde_ms)}`;
  const m = $("alarma-motivo");
  m.textContent = a.motivo;
  m.title = a.motivo;
}

function pintarBotones() {
  const hayPin = Boolean(sessionStorage.getItem(CLAVE_PIN));
  const pe = $("pin-estado");
  pe.textContent = hayPin ? "PIN guardado en esta pestaña" : "Piden el PIN";
  pe.className = `pide-pin${hayPin ? " guardado" : ""}`;

  // Romper o simular solo tiene sentido con producción sana y la alarma fuera de ALARM:
  // EventBridge avisa cuando la alarma CAMBIA de estado, no mientras sigue en ALARM.
  let bloqueo = "";
  if (!estado) bloqueo = "Esperando el estado de la API…";
  else if (estado.alarma.estado === "ALARM") bloqueo = "Para romper o simular, espera a que la alarma vuelva a OK.";
  else if (estado.produccion.salud !== "sana") bloqueo = `live está en v${estado.produccion.live}: aprueba el rollback o restaura.`;
  const aviso = $("a-bloqueo");
  aviso.textContent = bloqueo;
  aviso.hidden = !bloqueo;
  $("b-provocar").disabled = ocupado || Boolean(bloqueo);
  $("b-simular").disabled = ocupado || Boolean(bloqueo);
  $("b-restaurar").disabled = ocupado;
}

function pasosDelIncidente() {
  const i = incidente;
  const d = i && i.diagnostico ? i.diagnostico.diagnostico || {} : null;
  const falsa = d && (d.posible_falsa_alarma || !d.comando_remediacion);
  const primero = !i ? { titulo: "Mal despliegue" }
    : i.tipo === "simulada" ? { titulo: "Alarma forzada", ms: i.desde, detalle: "set-alarm-state, sin errores nuevos" }
    : i.tipo === "detectado" && !i.despliegue_ms && !i.version_rota
      ? { titulo: "Alarma forzada o sin despliegue", neutro: true, detalle: "La disparó otra terminal o pestaña" }
    : { titulo: "Mal despliegue", ms: i.despliegue_ms,
        detalle: i.version_rota ? `live a v${i.version_rota}${i.db_host ? ` (DB_HOST=${i.db_host})` : ""}` : "no lo vio esta pestaña" };
  const pasos = [
    { clave: "despliegue", ...primero },
    { clave: "alarma", titulo: "Suena la alarma", ms: i && i.alarma_ms, espera: "Tarda de 1 a 3 min" },
    { clave: "diagnostico", titulo: "Diagnóstico del N1", ms: i && i.diagnostico_ms, espera: "De 10 a 30 s tras la alarma",
      detalle: d ? `${d.severidad}${d.posible_falsa_alarma ? " · posible falsa alarma" : ""}` : "" },
    { clave: "aprobacion", titulo: "Tú apruebas", ms: i && i.aprobado_ms, espera: "Esperando tu decisión" },
  ];
  if (i && i.aprobacion) {
    pasos[3].detalle = `live a v${i.aprobacion.version_nueva} · ${i.aprobacion.ok} de ${i.aprobacion.invocaciones} sin error`;
  } else if (falsa) {
    pasos[3] = { clave: "aprobacion", titulo: "Nada que aprobar", neutro: true, detalle: "El N1 no propone cambios" };
  }
  return pasos;
}

function pintarLinea() {
  const lista = $("pasos");
  lista.replaceChildren();
  const tipo = $("linea-tipo");
  tipo.className = "etiqueta";
  tipo.textContent = "";
  if (incidente) {
    const nombres = { fallo: "Mal despliegue", simulada: "Falsa alarma simulada", detectado: "Detectado por la alarma" };
    tipo.textContent = nombres[incidente.tipo] || "";
    tipo.classList.add(incidente.tipo === "simulada" ? "simulada" : "fallo");
  }
  const pasos = pasosDelIncidente();
  let anterior = null;
  let activoPuesto = !incidente;     // sin incidente no hay paso "en espera"
  pasos.forEach((p, n) => {
    let clase = "paso";
    let horaTexto = "--:--:--";
    let detalle = p.detalle || "";
    if (p.neutro) {
      clase += " neutro";
      horaTexto = "—";
    } else if (p.ms) {
      clase += " hecho";
      horaTexto = hora(p.ms);
      if (anterior) detalle = `+${duracion(p.ms - anterior)}${detalle ? ` · ${detalle}` : ""}`;
      anterior = p.ms;
    } else if (!activoPuesto) {
      clase += " activo";
      horaTexto = p.espera || "En espera";
      activoPuesto = true;
    }
    lista.append(el("li", { class: `${clase} p-${p.clave}` },
      el("div", { class: "paso-cabeza" }, el("span", { class: "paso-num", text: String(n + 1) }),
        el("span", { class: "paso-titulo", text: p.titulo })),
      el("div", { class: "paso-hora", text: horaTexto }),
      detalle ? el("div", { class: "paso-detalle", text: detalle }) : null));
  });
}

function pintarDiagnostico() {
  const crudo = $("crudo").checked;
  const i = incidente;
  const firma = JSON.stringify([i && i.desde, i && i.diagnostico_ms, i && i.aprobado_ms, i && i.alarma_ms,
    i && i.fallo_n1, i && i.sin_dx, crudo, ocupado, estado && estado.produccion.estable]);
  if (firma === firmaDx) return;
  firmaDx = firma;
  const caja = $("dx");
  caja.replaceChildren();
  $("crudo-control").hidden = !(i && i.diagnostico);

  if (!i) {
    caja.append(el("div", { class: "vacio" },
      el("p", { class: "grande", text: "Sin incidentes por ahora." }),
      el("p", { text: "Cuando la alarma pase a ALARM, EventBridge despierta al N1. Junta métricas, logs y despliegues, " +
        "se los pasa a Claude y deja aquí su propuesta. Su rol es de solo lectura: no puede ejecutar nada." }),
      el("div", { class: "flujo" },
        el("div", {}, el("strong", { text: "1. Alarma" }), "CloudWatch ve 3 o más errores en un minuto."),
        el("div", {}, el("strong", { text: "2. EventBridge" }), "Lleva el cambio de estado a la Lambda del N1."),
        el("div", {}, el("strong", { text: "3. Diagnóstico" }), "Claude responde un JSON con la causa y un comando."),
        el("div", {}, el("strong", { text: "4. Tú decides" }), "Si apruebas, la consola ejecuta el rollback."))));
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
    const texto = !i.alarma_ms
      ? (i.tipo === "simulada" ? "Forzando la alarma…" : "Esperando a que la alarma pase a ALARM. La métrica de Lambda es por minuto: tarda de 1 a 3 min.")
      : `La alarma sonó a las ${hora(i.alarma_ms)}. El N1 está leyendo métricas, logs y despliegues, y consultando a Claude (de 10 a 30 s).`;
    caja.append(el("div", { class: "esperando" }, el("span", { class: "giro", "aria-hidden": "true" }), el("span", { text: texto })));
    return;
  }

  const r = i.diagnostico;
  if (crudo) {
    caja.append(el("pre", { class: "json", text: JSON.stringify(r, null, 2) }));
    return;
  }
  const d = r.diagnostico || {};
  const b = r.bedrock || {};
  const meta = [`${nombreModelo(r.modelo)} en Bedrock`];
  if (b.latencia_s != null) meta.push(`${numero(b.latencia_s, 1)} s`);
  if (b.inputTokens != null) meta.push(`${numero(b.inputTokens)} tokens de entrada y ${numero(b.outputTokens)} de salida`);

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
  if (v && estable && v !== estable && !ap) {
    caja.append(el("p", { class: "alerta mal", text: `Ojo: propone volver a la v${v}, y la versión estable es la v${estable}.` }));
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

// ── Arranque ────────────────────────────────────────────────
$("b-provocar").addEventListener("click", () => accion("provocar"));
$("b-simular").addEventListener("click", () => accion("simular"));
$("b-restaurar").addEventListener("click", () => accion("restaurar"));
$("crudo").addEventListener("change", () => pintarDiagnostico());
// Oculta: se cancela el sondeo programado. Visible otra vez: refresco inmediato.
document.addEventListener("visibilitychange", () => { if (visible()) ciclo(); else programar(); });
pintar();
ciclo();
