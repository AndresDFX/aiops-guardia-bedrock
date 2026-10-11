# Guardia N1 — Ingeniero DevOps de guardia con Amazon Bedrock

Alarma de CloudWatch → EventBridge → Lambda (contexto) → Claude Sonnet 4.6 (Bedrock, Converse)
→ diagnóstico JSON con severidad, causa raíz y comando exacto → CloudWatch Logs + SNS.
El N1 **no ejecuta** nada: propone, un humano aprueba, en la terminal o en una consola web.

Pensado para **AWS CloudShell en us-east-1** (AWS CLI v2, python3, zip). La ruta principal es
**Terraform** (`terraform/`); `template.yaml` con `deploy.sh` es la alternativa en CloudFormation.
Las dos crean los mismos recursos con los mismos nombres y usan los mismos scripts de la demo.

| Archivo | Qué hace |
|---|---|
| `terraform/` | La infraestructura en Terraform: app de demo + alias `live`, alarma, regla, Lambda de guardia, IAM de mínimo privilegio, SNS y, en `web.tf`, la consola web |
| `web/` y `src-web/control.py` | La consola web: la página (HTML, CSS y JS) y la Lambda de control que atiende sus botones. Solo la ruta Terraform |
| `template.yaml` | Lo mismo en CloudFormation |
| `lambda_function.py` | Recoge contexto, llama a Bedrock con el `SYSTEM_PROMPT`, valida el JSON y publica |
| `provocar_fallo.sh` | Mal despliegue real: `DB_HOST` inválido, nueva versión, alias `live` y 12 peticiones |
| `ver_diagnostico.sh` | Muestra el último diagnóstico y lo guarda en `salidas/` |
| `restaurar.sh` | Vuelve a la versión estable (`.version-estable`, Output `StableVersion`, el estado de Terraform o, si no hay ninguno, la variable `STABLE_VERSIONS` del N1), deja `DB_HOST=localhost` y espera a que la alarma vuelva sola a OK |
| `simular_alarma.sh` | Fuerza la alarma sin errores nuevos: la prueba de falsa alarma. No sirve de plan B con producción rota: el modelo la trata como falsa alarma |
| `deploy.sh` | Ruta CloudFormation: empaqueta, sube a un bucket temporal y despliega (`EMAIL=... ./deploy.sh` para recibir el correo) |
| `destroy.sh` | Ruta CloudFormation: borra el stack y el bucket |

## Antes de empezar: el modelo

Por defecto, **Claude Sonnet 4.6** por el perfil `us.anthropic.claude-sonnet-4-6`. La primera
llamada al modelo hazla tú, no la Lambda: es la que activa el acuerdo de Marketplace de la cuenta.

```bash
export AWS_REGION=us-east-1
aws bedrock-runtime converse --model-id us.anthropic.claude-sonnet-4-6 \
  --messages '[{"role":"user","content":[{"text":"Responde solo con la palabra: listo"}]}]' \
  --query 'output.message.content[?text].text | [0]' --output text
aws bedrock get-foundation-model-availability --model-id anthropic.claude-sonnet-4-6 \
  --query agreementAvailability.status --output text
```

El segundo comando debe decir `AVAILABLE` (tardó ~1 min en la cuenta del laboratorio). Si el
primero responde `AccessDeniedException ... is not available for this account`, mira la cuota del
modelo en Service Quotas (tokens por minuto): con la cuota en 0, Bedrock da ese error aunque el
acuerdo esté `AVAILABLE`. Le pasó a Sonnet 5.5 en la cuenta del laboratorio. Sonnet 4.5 está en
Legacy desde el 8-oct-2026.

## Con Terraform (ruta principal)

Terraform no viene en CloudShell y se borra al cerrar la sesión: se instala en cada sesión.

```bash
# 1. Instalar Terraform (comandos oficiales de HashiCorp para Amazon Linux, ~1 min)
sudo yum install -y yum-utils shadow-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform

# 2. El provider de AWS pesa ~800 MB y $HOME solo tiene 1 GB: la caché va en /tmp
export TF_PLUGIN_CACHE_DIR=/tmp/terraform-plugins
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# 3. Desplegar, romper, diagnosticar, restaurar y borrar (desde la raíz del repo)
chmod +x *.sh
terraform -chdir=terraform init      # ~40 s
terraform -chdir=terraform apply     # escribe yes; 38 recursos en ~35 s (18 en ~28 s sin la consola web)
./provocar_fallo.sh                  # el diagnóstico llega 1-2 min después
./ver_diagnostico.sh
./restaurar.sh                       # hasta ~1,5 min: espera a que la alarma vuelva sola a OK
terraform -chdir=terraform destroy   # escribe yes; ~3,5 min por CloudFront (~15 s sin la consola web)
```

- **`./destroy.sh` es el de CloudFormation**: si encuentra recursos en
  `terraform/terraform.tfstate`, avisa y sale con error sin borrarlos.
- El estado (`terraform/terraform.tfstate`) vive en `$HOME` y sobrevive a la sesión. No borres la
  carpeta antes del `destroy`.
- En una sesión nueva repite los pasos 1 y 2 y `terraform -chdir=terraform init` antes de `plan`,
  `output` o `destroy`. `restaurar.sh` no necesita Terraform: lee la versión estable de
  `.version-estable`, que el `apply` deja en la raíz del repo; si no está, del estado, y si tampoco,
  de la variable `STABLE_VERSIONS` del N1. Así funciona hasta en una sesión que no desplegó nada.
- El despliegue le pasa al N1 la última versión buena conocida (`STABLE_VERSIONS`, la que congela
  `terraform_data`), y el N1 la incluye siempre en su contexto, aunque haya quedado fuera de las
  versiones recientes que mira. Sin eso, tras varios despliegues rotos llegó a proponer volver a una
  versión sana que no era la estable.
- Después de aprobar el rollback, `terraform plan` muestra cambios: `provocar_fallo.sh` dejó el
  `DB_HOST` malo en `$LATEST`. Después de `./restaurar.sh` vuelve a decir "No changes".
- Diferencias con `template.yaml`: no hay bucket de despliegue (`archive_file` empaqueta
  `lambda_function.py`), la versión estable se congela en `terraform_data` para que un `apply`
  después de la demo no mueva `live` a la versión rota, y un `check` avisa si el perfil de
  inferencia enruta a una región que la política IAM no autoriza.

## La consola web (ruta Terraform)

El `apply` despliega también una consola web: una página estática en un bucket S3 privado, servida
por CloudFront con origin access control, y su API en el mismo dominio (`/api/*`) hacia un HTTP API y
una Lambda de control, `guardia-web`. Muestra producción, la alarma, la línea de tiempo y el
diagnóstico, y tiene cuatro botones: Provocar mal despliegue, Simular falsa alarma, Restaurar y
Aprobar y ejecutar rollback.

```bash
terraform -chdir=terraform output -raw web_url; echo
terraform -chdir=terraform output -raw web_pin; echo   # el PIN de los botones
```

- CloudFront tarda en publicar el dominio: la página respondió entre 1 y 2,5 min después del `apply`.
  Si no abre, espera y recarga.
- Mirarla no pide nada. Las acciones piden el PIN (cabecera `X-Pin`, 8 cifras, lo genera Terraform);
  sin él, 401.
- El N1 no gana permisos. El rol de `guardia-web` solo mueve el alias y cambia la configuración de la
  app de pagos, fuerza su alarma y lee los logs del N1. Aprobar no ejecuta texto: valida que el comando
  sea un `update-alias` de `live` a una versión que existe (rechazó con 400 los 10 comandos maliciosos
  de la prueba).
- Costo: menos de USD 0,01 por hora con la página abierta (CloudFront, HTTP API y Lambda cobran por
  petición). La página pide el estado cada 15 s en reposo y cada 3 s durante un incidente, y nada con
  la pestaña oculta; las métricas salen de `GetMetricStatistics`, dentro de la capa gratuita de
  CloudWatch, con una caché de 30 s. Cerrada, nada.
- `terraform -chdir=terraform apply -var web_enabled=false` deja la demo solo de terminal: 18 recursos
  y un `destroy` de ~15 s. Pasa el mismo `-var` al `destroy`.

## Con CloudFormation (alternativa)

```bash
export AWS_REGION=us-east-1
chmod +x *.sh
./deploy.sh              # 2-3 min la primera vez
./provocar_fallo.sh      # el diagnóstico llega 1-2 min después
./ver_diagnostico.sh
./restaurar.sh
./destroy.sh             # ~2 min
```

## Lo medido (Sonnet 4.6, 10-oct-2026)

La alarma pasa a `ALARM` entre 35 y 96 s después de que termina `provocar_fallo.sh`, y el diagnóstico
llega 8-10 s después a los logs (en la consola web, de 7 a 22 s). Bedrock tarda de 6,6 a 8,6 s. Usa de
1 870 a 3 150 tokens de entrada y de 670 a 870 de salida, y cuesta ≈ USD 0,02 con el perfil `us.` (USD
3,30 por millón de tokens de entrada y 16,50 por millón de salida). Con el código final, 9 de 9 fallos
reales dieron SEV1 con el rollback exacto a la versión estable.


