# ═════════════════════════════════════════════════════════════
# Guardia N1 - AIOps event-driven con Amazon Bedrock (variante Terraform)
#   CloudWatch Alarm -> EventBridge -> Lambda (recoge contexto) -> Bedrock Claude Sonnet 4.6
#   -> diagnostico JSON (severidad, causa raiz, comando exacto) -> CloudWatch Logs + SNS.
#   Mismos recursos, nombres y permisos que template.yaml: los scripts de la demo
#   (provocar_fallo.sh, ver_diagnostico.sh, restaurar.sh, simular_alarma.sh) no cambian.
# ═════════════════════════════════════════════════════════════

data "aws_caller_identity" "actual" {}

locals {
  cuenta      = data.aws_caller_identity.actual.account_id
  app_name    = "${var.project_name}-app-pagos"
  oncall_name = "${var.project_name}-oncall"
  perfil_arn  = "arn:aws:bedrock:${var.region}:${local.cuenta}:inference-profile/${var.model_id}"

  # Regiones a las que enruta el perfil us. de Sonnet 4.6 desde us-east-1. Comprobado el
  # 10-oct-2026 con:
  #   aws bedrock get-inference-profile --inference-profile-identifier us.anthropic.claude-sonnet-4-6
  # Si AWS agrega una region, el check "perfil_cubierto_por_iam" (al final) lo avisa en el plan.
  regiones_del_perfil = ["us-east-1", "us-east-2", "us-west-2"]

  confia_en_lambda = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ═════════════════════════════════════════════════════════════
# 1. EL SERVICIO QUE SE VA A ROMPER (solo para la demo)
#    Una Lambda "app-pagos" que en cada invocacion resuelve el DNS de
#    su base de datos (variable DB_HOST). Con DB_HOST=localhost funciona.
#    Con un host que no existe, falla DE VERDAD (no hay un if "modo_fallo").
#    Produccion la invoca por el alias "live", como un despliegue real.
# ═════════════════════════════════════════════════════════════
resource "aws_iam_role" "app" {
  name               = "${local.app_name}-role"
  assume_role_policy = local.confia_en_lambda
}

resource "aws_iam_role_policy_attachment" "app_logs" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# El log group se crea ANTES que la funcion (depends_on mas abajo). Si lo crea
# Lambda en la primera invocacion, queda sin retencion y sobrevive al destroy.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/lambda/${local.app_name}"
  retention_in_days = 1
}

# El mismo codigo que el ZipFile de template.yaml. CloudFormation lo guarda
# como index.py; archive_file lo empaqueta con ese mismo nombre.
data "archive_file" "app" {
  type             = "zip"
  output_path      = "${path.module}/.build/app-pagos.zip"
  output_file_mode = "0644"

  source {
    filename = "index.py"
    content  = <<-PY
      import os, socket, json
      def handler(event, context):
          host = os.environ["DB_HOST"]
          port = int(os.environ.get("DB_PORT", "5432"))
          try:
              socket.getaddrinfo(host, port)
          except OSError as exc:  # en Lambda un host inexistente da Errno 16, no gaierror
              print(f"ERROR conexion a base de datos fallida host={host} port={port}: {exc}")
              raise RuntimeError(f"No se pudo resolver {host}:{port}") from exc
          print(f"OK pago procesado db={host}:{port}")
          return {"statusCode": 200, "body": json.dumps({"pago": "aprobado"})}
    PY
  }
}

resource "aws_lambda_function" "app" {
  function_name = local.app_name
  # En template.yaml la funcion dice "Servicio de pagos de demo..." y su version estable
  # dice "estable (DB_HOST=localhost)". Terraform no tiene recurso de version:
  # publish = true publica con la descripcion de la funcion. Usamos la de la version
  # porque es la que lee el ingeniero de guardia (list-versions-by-function).
  description      = "estable (DB_HOST=localhost)"
  runtime          = "python3.12"
  handler          = "index.handler"
  role             = aws_iam_role.app.arn
  timeout          = 5
  memory_size      = 128
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256
  publish          = true

  environment {
    variables = {
      DB_HOST = "localhost"
      DB_PORT = "5432"
    }
  }

  depends_on = [aws_cloudwatch_log_group.app, aws_iam_role_policy_attachment.app_logs]
}

# La version que publica Terraform es la buena conocida: el destino del rollback.
# Ojo: aws_lambda_function.app.version es la ULTIMA version publicada, y
# provocar_fallo.sh publica una nueva (la rota). Si el alias siguiera ese atributo,
# un terraform apply despues de la demo moveria live a la version rota.
# Por eso la congelamos aqui: solo cambia cuando el propio Terraform publica otra
# version (porque cambiaste el codigo o la configuracion de app-pagos).
resource "terraform_data" "version_estable" {
  input = aws_lambda_function.app.version

  lifecycle {
    ignore_changes       = [input]
    replace_triggered_by = [aws_lambda_function.app.version]
  }

  # restaurar.sh lee este archivo de la raiz del repo (esta en .gitignore). Asi funciona
  # aunque CloudShell haya reiniciado la sesion: Terraform y su cache de /tmp se pierden,
  # el archivo no, porque vive en $HOME. Si el comando falla (por ejemplo en Windows sin
  # sh), el apply sigue y restaurar.sh usa terraform output o el estado.
  provisioner "local-exec" {
    command    = "echo ${self.output} > ${path.module}/../.version-estable"
    on_failure = continue
  }

  provisioner "local-exec" {
    when       = destroy
    command    = "rm -f ${path.module}/../.version-estable"
    on_failure = continue
  }
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.app.function_name
  function_version = terraform_data.version_estable.output
}

# ═════════════════════════════════════════════════════════════
# 2. LA ALARMA (el "pager")
#    3 o mas errores en 1 minuto. Periodo de 60 s: las metricas de
#    Lambda son de 1 minuto, asi que la alarma reacciona rapido.
#    El nombre empieza por ${project_name}- : asi la ve EventBridge.
# ═════════════════════════════════════════════════════════════
resource "aws_cloudwatch_metric_alarm" "errores" {
  alarm_name          = "${local.app_name}-errores"
  alarm_description   = "Errores en el servicio de pagos (umbral 3 por minuto)"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.app.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

# ═════════════════════════════════════════════════════════════
# 3. EL CANAL DEL INCIDENTE — SNS
# ═════════════════════════════════════════════════════════════
resource "aws_sns_topic" "incidentes" {
  name         = "${var.project_name}-incidentes"
  display_name = "Guardia N1"
}

resource "aws_sns_topic_subscription" "correo" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.incidentes.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ═════════════════════════════════════════════════════════════
# 4. EL INGENIERO DE GUARDIA — Lambda + rol de SOLO LECTURA
#    Minimo privilegio: puede leer contexto e invocar UN modelo.
#    No puede cambiar nada de la infraestructura: propone, no ejecuta.
# ═════════════════════════════════════════════════════════════
resource "aws_iam_role" "oncall" {
  name               = "${local.oncall_name}-role"
  assume_role_policy = local.confia_en_lambda
}

resource "aws_iam_role_policy_attachment" "oncall_logs" {
  role       = aws_iam_role.oncall.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "bedrock" {
  name = "BedrockSoloEsteModelo"
  role = aws_iam_role.oncall.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Con un inference profile se autorizan DOS cosas: el perfil y el
      # modelo base en cada region a la que el perfil puede enrutar.
      {
        Sid      = "InvocarPerfil"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = local.perfil_arn
      },
      {
        Sid      = "InvocarModeloBaseViaPerfil"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = [for r in local.regiones_del_perfil : "arn:aws:bedrock:${r}::foundation-model/${var.foundation_model_id}"]
        Condition = {
          StringLike = { "bedrock:InferenceProfileArn" = local.perfil_arn }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "contexto" {
  name = "LeerContexto"
  role = aws_iam_role.oncall.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Los datos de la alarma llegan en el evento: no hace falta cloudwatch:DescribeAlarms.
      {
        Sid      = "MetricasNoAdmitenArn"
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricData"
        Resource = "*"
      },
      {
        Sid      = "LogsDelServicio"
        Effect   = "Allow"
        Action   = "logs:FilterLogEvents"
        Resource = "arn:aws:logs:${var.region}:${local.cuenta}:log-group:/aws/lambda/${var.project_name}-*"
      },
      {
        Sid    = "QueCambioEnElServicio"
        Effect = "Allow"
        Action = [
          "lambda:GetFunctionConfiguration",
          "lambda:ListAliases",
          "lambda:ListVersionsByFunction",
        ]
        Resource = ["arn:aws:lambda:${var.region}:${local.cuenta}:function:${var.project_name}-*"]
      },
      {
        Sid      = "QuienToco"
        Effect   = "Allow"
        Action   = "cloudtrail:LookupEvents"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "publicar" {
  name = "PublicarIncidente"
  role = aws_iam_role.oncall.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.incidentes.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "oncall" {
  name              = "/aws/lambda/${local.oncall_name}"
  retention_in_days = 1
}

# Una sola fuente de verdad: el mismo lambda_function.py que usa CloudFormation.
# archive_file lo empaqueta en cada plan; si el codigo cambia, cambia el hash y
# Terraform actualiza la Lambda. Sin bucket de S3 de por medio.
data "archive_file" "oncall" {
  type             = "zip"
  source_file      = "${path.module}/../lambda_function.py"
  output_path      = "${path.module}/.build/oncall.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_function" "oncall" {
  function_name    = local.oncall_name
  description      = "Ingeniero DevOps de guardia N1 (Bedrock)"
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  role             = aws_iam_role.oncall.arn
  timeout          = 90
  memory_size      = 256
  filename         = data.archive_file.oncall.output_path
  source_code_hash = data.archive_file.oncall.output_base64sha256

  environment {
    variables = {
      MODEL_ID      = var.model_id
      SNS_TOPIC_ARN = aws_sns_topic.incidentes.arn
      PROJECT_NAME  = var.project_name
      # La ultima version buena conocida de cada servicio, como la sabe el despliegue: la que
      # congela terraform_data, no la ultima publicada. El N1 la pone SIEMPRE en su contexto,
      # aunque haya quedado fuera de las versiones recientes que mira. Si un apply publica una
      # estable nueva, ese mismo apply se la pasa. JSON {"funcion": "version"}.
      STABLE_VERSIONS = jsonencode({ (aws_lambda_function.app.function_name) = terraform_data.version_estable.output })
    }
  }

  # Igual que en CloudFormation: la funcion nace con su log group y su rol completo.
  depends_on = [
    aws_cloudwatch_log_group.oncall,
    aws_iam_role_policy_attachment.oncall_logs,
    aws_iam_role_policy.bedrock,
    aws_iam_role_policy.contexto,
    aws_iam_role_policy.publicar,
  ]
}

# ═════════════════════════════════════════════════════════════
# 5. EL GATILLO — regla de EventBridge
#    Cualquier alarma de este proyecto que pase a ALARM despierta
#    al ingeniero de guardia. No hay polling: es un sensor, no una ronda.
# ═════════════════════════════════════════════════════════════
resource "aws_cloudwatch_event_rule" "alarma" {
  name        = "${var.project_name}-alarma-a-oncall"
  description = "Alarmas del proyecto en estado ALARM -> Lambda de guardia"
  state       = "ENABLED"
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "${var.project_name}-" }]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "oncall" {
  rule      = aws_cloudwatch_event_rule.alarma.name
  target_id = "OnCall"
  arn       = aws_lambda_function.oncall.arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 600
  }
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "PermitirReglaDeAlarmas"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.oncall.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarma.arn
}

# ─────────────────────────────────────────────────────────────
# Si AWS amplia el perfil a otra region y la politica no la autoriza,
# Bedrock da AccessDenied solo cuando enruta alli: un fallo intermitente,
# el peor de depurar. Este check compara la lista de arriba con el perfil
# real en cada plan y avisa (no bloquea el apply) si falta alguna region.
# El data source va fuera del check a proposito: dentro, cada plan lo
# muestra como un cambio pendiente aunque no haya nada que cambiar.
# ─────────────────────────────────────────────────────────────
data "aws_bedrock_inference_profile" "perfil" {
  inference_profile_id = var.model_id
}

check "perfil_cubierto_por_iam" {
  assert {
    condition = alltrue([
      for m in data.aws_bedrock_inference_profile.perfil.models :
      contains(local.regiones_del_perfil, split(":", m.model_arn)[3])
    ])
    error_message = "El perfil ${var.model_id} enruta a regiones que la politica IAM no autoriza: ${join(", ", [for m in data.aws_bedrock_inference_profile.perfil.models : split(":", m.model_arn)[3] if !contains(local.regiones_del_perfil, split(":", m.model_arn)[3])])}. Agregalas a local.regiones_del_perfil en main.tf."
  }
}
