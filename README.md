# Guardia N1 — Ingeniero DevOps de guardia con Amazon Bedrock

Alarma de CloudWatch → EventBridge → Lambda (contexto) → Claude Sonnet 4.6 (Bedrock, Converse)
→ diagnóstico JSON con severidad, causa raíz y comando exacto → CloudWatch Logs + SNS.
El N1 **no ejecuta** nada: propone, un humano aprueba, en la terminal o en una consola web.

Pensado para **AWS CloudShell en us-east-1** (AWS CLI v2, python3). Un script crea todo y otro lo
borra; entre los dos, un script por cada acción de la demo. La infraestructura es **Terraform**
(`terraform/`); `template.yaml` es la alternativa en CloudFormation, con sus propios scripts.

## De punta a punta

```bash
git clone https://github.com/AndresDFX/aiops-guardia-bedrock.git && cd aiops-guardia-bedrock

./deploy.sh            # crea todo: comprueba el modelo, instala Terraform si falta, init y apply
./logs.sh              # en una segunda columna: la terminal del ingeniero de guardia
./provocar_fallo.sh    # un mal despliegue real; la alarma suena en 1-2 min
./ver_diagnostico.sh   # severidad, causa raíz y el comando que propone el N1
./aprobar.sh           # valida ese comando, te pide confirmación y hace el rollback
./restaurar.sh         # deja todo sano y espera a que la alarma vuelva a OK
./simular_alarma.sh    # la prueba de honestidad: alarma forzada sin errores nuevos
./destroy.sh           # borra todo y comprueba en la cuenta que no quedó nada
```

Dos terminales a la vista en CloudShell: **Actions → Tabs layout → Split into columns**. En la de la
derecha, `./logs.sh`; en la de la izquierda, el resto.

| Script | Qué hace |
|---|---|
| `deploy.sh` | Comprueba la cuenta, la región, el perfil del modelo, el acuerdo de Marketplace y la cuota; instala Terraform si falta; `init` y `apply`. Imprime la URL de la consola web, el PIN y la versión estable. Se puede repetir: si ya está desplegada, no cambia nada |
| `logs.sh` | `aws logs tail` del N1 en vivo, sin las dos líneas JSON largas |
| `provocar_fallo.sh` | Mal despliegue real: `DB_HOST` inválido, versión nueva, alias `live` y 12 peticiones |
| `ver_diagnostico.sh` | Muestra el último diagnóstico de este incidente y lo guarda en `salidas/` |
| `aprobar.sh` | Valida el `comando_remediacion` con la misma regla que el botón Aprobar de la web y, si lo confirmas, ejecuta **su propio** `update-alias` (nunca el texto del modelo); luego 5 pagos de prueba |
| `restaurar.sh` | `live` a la versión estable, `DB_HOST=localhost` y espera a que la alarma vuelva sola a OK |
| `simular_alarma.sh` | Fuerza la alarma sin errores nuevos. No sirve de plan B con producción rota: el modelo la trata como falsa alarma |
| `destroy.sh` | Borra todo con Terraform, aunque CloudShell se haya reiniciado, y consulta la cuenta para comprobar que no quedó nada |
| `deploy-cloudformation.sh` · `destroy-cloudformation.sh` | La ruta alternativa en CloudFormation (sin consola web) |
| `_comun.sh` | Nombres y funciones que comparten los scripts |
| `terraform/`, `template.yaml` | La infraestructura: app de demo + alias `live`, alarma, regla, Lambda de guardia, IAM de mínimo privilegio, SNS y, en `web.tf`, la consola web |
| `lambda_function.py` | El N1: recoge contexto, llama a Bedrock con el `SYSTEM_PROMPT`, valida el JSON y publica |
| `web/` y `src-web/control.py` | La consola web: la página y la Lambda de control que atiende sus botones |

## Lo que comprueba deploy.sh antes de crear nada

Por defecto el modelo es **Claude Sonnet 4.6** por el perfil `us.anthropic.claude-sonnet-4-6`.

1. Que el perfil exista en tu región y solo enrute a regiones que la política IAM autoriza
   (desde us-east-1: us-east-1, us-east-2 y us-west-2).
2. El acuerdo de la cuenta con el modelo (`get-foundation-model-availability`). Si no está
   `AVAILABLE`, hace la **primera invocación con tu usuario**, que es la que lo activa (nunca la
   Lambda), y espera hasta 5 min a que pase a `AVAILABLE`.
3. La cuota de tokens por minuto del perfil `us.`: con la cuota en 0, Bedrock responde `is not
   available for this account` aunque el acuerdo diga `AVAILABLE`.

Si algo falla, no despliega y dice qué hacer:

| Bedrock responde | Qué hacer |
|---|---|
| `Model use case details have not been submitted` | Formulario de Anthropic: Bedrock → Model catalog → Claude Sonnet 4.6 → Submit use case details |
| `INVALID_PAYMENT_INSTRUMENT` | Un método de pago válido: Claude se cobra por AWS Marketplace, que el plan Free no incluye |
| `... aws-marketplace:Subscribe ...` | Un usuario administrador (permisos de Marketplace) |
| `is not available for this account` | La cuenta tiene cuota 0 para el modelo: usa otra cuenta |
| `The provided model identifier is invalid` | Otra región: `export AWS_REGION=us-east-1` |
| `... still being processed` | La suscripción se está procesando: espera unos minutos y repite `./deploy.sh` |

## Lo que conviene saber de deploy.sh y destroy.sh

- **Opciones:** `EMAIL=tu@correo.com ./deploy.sh` (el diagnóstico llega también por correo),
  `WEB=false ./deploy.sh` (sin consola web: 18 recursos y un destroy de ~15 s), `OCULTAR_PIN=1`
  (no muestra el PIN si la pantalla está proyectada) y, para otro modelo, los dos IDs:
  `MODEL_ID=... FOUNDATION_MODEL_ID=... ./deploy.sh`. Quedan en `terraform/deploy.auto.tfvars`, que
  Terraform lee solo: el siguiente `./deploy.sh`, `./destroy.sh` y un `terraform plan` a mano usan los
  mismos valores. Está en `.gitignore` porque puede llevar tu correo.
- **CloudShell borra Terraform al cerrar la sesión** (va a `/usr/bin`) y `$HOME` tiene 1 GB. Los dos
  scripts instalan Terraform si falta (comandos oficiales de HashiCorp para Amazon Linux), dejan la
  caché de providers en `/tmp/terraform-plugins` (el de AWS pesa ~800 MB) y hacen el `init` en cada
  sesión. El estado (`terraform/terraform.tfstate`) vive en `$HOME`: no borres la carpeta antes del
  `./destroy.sh`.
- **`./destroy.sh` no necesita que repitas `WEB=...`:** el destroy actúa sobre el estado. Probado en
  las dos direcciones: con `-var web_enabled=false` sobre la demo con consola, el plan marca los 38
  recursos; con el valor por defecto sobre la demo sin consola, borró los 18.
- **Las dos rutas no conviven:** usan los mismos nombres. `./deploy.sh` se niega si existe el stack de
  CloudFormation, `./deploy-cloudformation.sh` si el estado de Terraform tiene recursos, y cada
  destroy manda al otro si lo que queda es de la otra ruta.
- `restaurar.sh` y `aprobar.sh` no necesitan Terraform: leen la versión estable de `.version-estable`,
  que deja el despliegue; si no está, del stack, del estado o de la variable `STABLE_VERSIONS` del N1.
- El despliegue le pasa al N1 la última versión buena conocida (`STABLE_VERSIONS`, la que congela
  `terraform_data`), y el N1 la incluye siempre en su contexto. Sin eso, tras varios despliegues rotos
  llegó a proponer volver a una versión sana que no era la estable.
- Después de aprobar el rollback, `terraform plan` muestra cambios: `provocar_fallo.sh` dejó el
  `DB_HOST` malo en `$LATEST`. Después de `./restaurar.sh` vuelve a decir "No changes".

## La consola web

`./deploy.sh` despliega también una consola web: una página estática en un bucket S3 privado, servida
por CloudFront con origin access control, y su API en el mismo dominio (`/api/*`) hacia un HTTP API y
una Lambda de control, `guardia-web`. La URL y el PIN los imprime `./deploy.sh` (si los pierdes,
córrelo otra vez: no cambia nada). Lo que muestra:

- **Recorrido del incidente en AWS:** los siete pasos por los que pasa el incidente (app de pagos,
  alarma, regla de EventBridge, el N1, Bedrock, el diagnóstico en Logs y SNS, y tú), que se encienden en
  orden con su hora. Cada paso tiene enlaces ↗ a la consola de AWS: la alarma, la regla, las versiones de
  la app, CloudTrail, el modelo y los logs de **esa** invocación del N1. Solo llevan la región y los
  nombres, nunca el ID de cuenta, y abren la consola de quien tenga la sesión iniciada en la cuenta.
- **Siguiente paso:** qué hacer ahora (esperar la alarma, comparar la versión, aprobar, restaurar…).
- Producción, la alarma y las acciones: Provocar mal despliegue, Simular falsa alarma y Restaurar.
- El diagnóstico, en tres pestañas: **Diagnóstico** (con Aprobar y ejecutar rollback), **Contexto que
  vio el N1** (el `CONTEXTO_JSON` que la Lambda le mandó a Claude: métricas por minuto, errores
  agrupados, versiones con live y la estable, cambios en CloudTrail) y **JSON** (los dos, tal cual).

La traza sale del log del N1: `/api/diagnostico` lee sus líneas `[guardia] ...`, `CONTEXTO_JSON` y
`DIAGNOSTICO_JSON` de la última invocación y devuelve cuándo lo despertó EventBridge, cuánto tardaron
el contexto y Bedrock y cuándo publicó en SNS. El rol de la consola ya podía leer ese log: no ganó
permisos.

- CloudFront tarda en publicar el dominio: la página respondió entre 1 y 2,5 min después del `apply`.
  Si no abre, espera y recarga.
- Mirarla no pide nada. Las acciones piden el PIN (8 cifras, lo genera Terraform); sin él, 401.
- El N1 no gana permisos. El rol de `guardia-web` solo mueve el alias y cambia la configuración de la
  app de pagos, fuerza su alarma y lee los logs del N1. Aprobar no ejecuta texto: valida que el comando
  sea un `update-alias` de `live` a una versión que existe. `./aprobar.sh` usa esa misma función,
  leída de `src-web/control.py`.
- Costo: menos de USD 0,01 por hora con la página abierta (CloudFront, HTTP API y Lambda cobran por
  petición). La página pide el estado cada 15 s en reposo y cada 3 s durante un incidente, y nada con
  la pestaña oculta; las métricas salen de `GetMetricStatistics`, dentro de la capa gratuita de
  CloudWatch. Cerrada, nada.

## Con CloudFormation (alternativa)

```bash
./deploy-cloudformation.sh     # mismas comprobaciones del modelo; ~3 min la primera vez
./logs.sh                      # y los mismos scripts de la demo
./provocar_fallo.sh
./ver_diagnostico.sh
./aprobar.sh
./restaurar.sh
./destroy-cloudformation.sh    # ~3 min; comprueba en la cuenta que no quedó nada
```

## Lo medido

Con Sonnet 4.6, el 10-oct-2026: la alarma pasa a `ALARM` entre 35 y 96 s después de que termina
`provocar_fallo.sh`, y el diagnóstico llega 8-10 s después a los logs. Bedrock tarda de 6,6 a 8,6 s,
usa de 1 870 a 3 150 tokens de entrada y de 670 a 870 de salida, y cuesta ≈ USD 0,02 con el perfil
`us.` (USD 3,30 por millón de tokens de entrada y 16,50 por millón de salida). Con el código final,
9 de 9 fallos reales dieron SEV1 con el rollback exacto a la versión estable.

Con estos scripts, el 12-oct-2026, en un contenedor que emula CloudShell (Amazon Linux 2023, sin
Terraform, `$HOME` persistente):

- `./deploy.sh` desde cero: 3 min 38 s (comprobaciones 12 s, instalar Terraform 83 s, `init` 78 s,
  `apply` de 38 recursos ~40 s). La segunda vez: 45 s y "No changes". La consola ya respondía 200 a
  1 min 53 s del final.
- Incidente: `ALARM` 25 s después de que terminó `provocar_fallo.sh` y diagnóstico SEV1 8 s después,
  con el rollback a la versión estable. `./aprobar.sh`: 15 de 15 pagos de prueba atendidos por la
  estable en tres aprobaciones; con 6 diagnósticos falsos (5 comandos fuera de la regla y uno vacío),
  `live` no se movió. `./simular_alarma.sh`: SEV4, posible falsa alarma y nada que aprobar.
- `./destroy.sh` en una sesión nueva: reinstala Terraform, hace el `init`, borra los 38 recursos
  (`terraform destroy`, 3 min 33 s, casi todo CloudFront) y la cuenta queda limpia. La instalación y
  el `init` dependen de la red: 2 min 40 s en la primera corrida y 18 min con la red lenta de esa hora.
- CloudFormation: `./deploy-cloudformation.sh` 3 min 17 s y `./destroy-cloudformation.sh` 2 min 56 s.

Con la consola del recorrido y los enlaces, el 18-oct-2026, en el mismo contenedor y con otro prefijo
(`PROJECT=guardiaux`, 38 recursos):

- `./deploy.sh` desde cero: 5 min 56 s. La página respondió 20 s después.
- Incidente por la consola: la alarma saltó 1 min 3 s después del mal despliegue; EventBridge despertó
  al N1 en 1 s; contexto en 1,1 s; Bedrock en 6,4 s (1.903 tokens de entrada y 705 de salida, ≈ USD
  0,018); el diagnóstico salió en pantalla 21 s después de la alarma, con el rollback a la estable.
  Aprobado: 5 de 5 pagos sin error. Tras Restaurar, la alarma volvió sola a OK en 26 s; la falsa
  alarma dio SEV4 sin comando en unos 10 s.
- Los 13 enlaces a la consola de AWS abrieron el recurso correcto (sesión federada de solo lectura).
- `./destroy.sh` en un contenedor nuevo: 6 min 00 s, y la cuenta quedó limpia.

Paso a paso para hacerlo en tu cuenta: la guía del participante, https://docs.google.com/document/d/1IBYyPOUXtjLfahEFQsnwzqiVEjUWGEfe/edit.
