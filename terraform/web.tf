# ═════════════════════════════════════════════════════════════
# 6. LA CONSOLA WEB (opcional: web_enabled, por defecto true)
#    Una pagina estatica en un bucket PRIVADO, servida por CloudFront, y
#    una API en el MISMO dominio (/api/*) que atiende una Lambda de control:
#    las manos del humano. El N1 no cambia: sigue con su rol de solo lectura.
#    La consola solo cambia algo cuando alguien pulsa un boton con el PIN.
#
#      navegador -> CloudFront (https://xxxx.cloudfront.net)
#                     /*      -> S3 privado (Origin Access Control)
#                     /api/*  -> HTTP API -> Lambda guardia-web
#
#    Con web_enabled = false no se crea nada de esta seccion y la demo
#    queda solo de terminal, como en la ruta de CloudFormation.
# ═════════════════════════════════════════════════════════════

locals {
  web_name = "${var.project_name}-web"
  web_dir  = "${path.module}/../web"

  # Tipo de cada archivo de la pagina segun su extension. El navegador no
  # ejecuta un .js que llegue como application/octet-stream.
  web_tipos = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "text/javascript; charset=utf-8"
  }
  web_archivos = var.web_enabled ? {
    for f in fileset(local.web_dir, "*.{html,css,js}") : f => local.web_tipos[reverse(split(".", f))[0]]
  } : {}
}

# ─────────────────────────────────────────────────────────────
# 6.1 La pagina: bucket privado. Nadie lo lee directo; solo CloudFront.
# ─────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "web" {
  count = var.web_enabled ? 1 : 0
  # Prefijo y sufijo aleatorio: nombre unico en todo S3 y sin el ID de cuenta.
  bucket_prefix = "${local.web_name}-"
  force_destroy = true # el destroy borra tambien los archivos de la pagina
}

resource "aws_s3_bucket_ownership_controls" "web" {
  count  = var.web_enabled ? 1 : 0
  bucket = aws_s3_bucket.web[0].id
  rule {
    object_ownership = "BucketOwnerEnforced" # sin ACL: manda solo la politica del bucket
  }
}

resource "aws_s3_bucket_public_access_block" "web" {
  count                   = var.web_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.web[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# etag = filemd5: si cambias un archivo, Terraform lo vuelve a subir.
# no-cache: el navegador pregunta siempre si hay version nueva (responde 304 si no).
resource "aws_s3_object" "web" {
  for_each      = local.web_archivos
  bucket        = aws_s3_bucket.web[0].id
  key           = each.key
  source        = "${local.web_dir}/${each.key}"
  etag          = filemd5("${local.web_dir}/${each.key}")
  content_type  = each.value
  cache_control = "no-cache"
}

# Solo ESTA distribucion puede leer el bucket. No es una politica publica:
# por eso convive con el bloqueo de acceso publico.
resource "aws_s3_bucket_policy" "web" {
  count  = var.web_enabled ? 1 : 0
  bucket = aws_s3_bucket.web[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SoloEstaDistribucionLee"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.web[0].arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.web[0].arn }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.web]
}

# ─────────────────────────────────────────────────────────────
# 6.2 CloudFront basico: dominio *.cloudfront.net con su certificado.
#     Dos origenes: el bucket para la pagina y el HTTP API para /api/*.
# ─────────────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "web" {
  count                             = var.web_enabled ? 1 : 0
  name                              = "${local.web_name}-oac"
  description                       = "CloudFront firma con SigV4 las lecturas del bucket de la consola"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Politicas administradas de AWS: no hace falta escribir las nuestras.
data "aws_cloudfront_cache_policy" "optimizada" {
  count = var.web_enabled ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "sin_cache" {
  count = var.web_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

# Pasa al API todo lo del navegador (cabeceras, query string, cuerpo) MENOS
# el Host: API Gateway necesita ver su propio dominio, no el de CloudFront.
data "aws_cloudfront_origin_request_policy" "todo_menos_host" {
  count = var.web_enabled ? 1 : 0
  name  = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "web" {
  count               = var.web_enabled ? 1 : 0
  enabled             = true
  comment             = "${var.project_name} - consola web del ingeniero de guardia N1"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # solo los bordes de America del Norte y Europa: lo mas barato
  is_ipv6_enabled     = true

  # El apply no espera a que CloudFront termine de propagarse (tarda minutos):
  # la terminal queda libre y la web responde poco despues. El destroy SI espera
  # siempre: CloudFront exige deshabilitar la distribucion antes de borrarla.
  wait_for_deployment = false

  origin {
    origin_id                = "pagina"
    domain_name              = aws_s3_bucket.web[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web[0].id
  }

  origin {
    origin_id   = "api"
    domain_name = replace(aws_apigatewayv2_api.web[0].api_endpoint, "https://", "")

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # La pagina: estatica y cacheable.
  default_cache_behavior {
    target_origin_id       = "pagina"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimizada[0].id
  }

  # La API: cada peticion llega al origen, sin cache, con todos los metodos.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.sin_cache[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.todo_menos_host[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ─────────────────────────────────────────────────────────────
# 6.3 La API: HTTP API -> Lambda de control. CloudFront la llama en /api/*.
# ─────────────────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "web" {
  count         = var.web_enabled ? 1 : 0
  name          = "${local.web_name}-api"
  protocol_type = "HTTP"
  description   = "API de la consola web de Guardia N1 (la llama CloudFront en /api/*)"
}

resource "aws_apigatewayv2_integration" "web" {
  count                  = var.web_enabled ? 1 : 0
  api_id                 = aws_apigatewayv2_api.web[0].id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.web[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "web" {
  count     = var.web_enabled ? 1 : 0
  api_id    = aws_apigatewayv2_api.web[0].id
  route_key = "ANY /api/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.web[0].id}"
}

resource "aws_apigatewayv2_stage" "web" {
  count       = var.web_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.web[0].id
  name        = "$default"
  auto_deploy = true

  # Freno para una URL que se proyecta en una sala: 10 peticiones por segundo,
  # rafagas de 20. La pagina pide el estado cada 15 s en reposo y cada 3 s
  # durante un incidente: caben varias pestanas.
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "web_api" {
  count         = var.web_enabled ? 1 : 0
  statement_id  = "PermitirHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.web[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.web[0].execution_arn}/*/*/api/*"
}

# ─────────────────────────────────────────────────────────────
# 6.4 La Lambda de control: las manos del humano.
#     Minimo privilegio: solo la app de pagos (sus versiones y su alias),
#     la alarma de la demo, las metricas y los logs del N1.
# ─────────────────────────────────────────────────────────────
resource "random_password" "pin" {
  count   = var.web_enabled ? 1 : 0
  length  = 8
  upper   = false
  lower   = false
  special = false
  numeric = true
}

resource "aws_iam_role" "web" {
  count              = var.web_enabled ? 1 : 0
  name               = "${local.web_name}-role"
  assume_role_policy = local.confia_en_lambda
}

resource "aws_iam_role_policy" "web_logs" {
  count = var.web_enabled ? 1 : 0
  name  = "EscribirSusLogs"
  role  = aws_iam_role.web[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.web[0].arn}:*"
    }]
  })
}

resource "aws_iam_role_policy" "web_manos" {
  count = var.web_enabled ? 1 : 0
  name  = "ManosDelHumano"
  role  = aws_iam_role.web[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppDePagosVersionesYAlias"
        Effect = "Allow"
        Action = [
          "lambda:GetAlias",
          "lambda:UpdateAlias",
          "lambda:GetFunctionConfiguration",
          "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:ListVersionsByFunction",
          "lambda:InvokeFunction",
        ]
        # Lambda autoriza por separado el ARN sin calificar (la funcion) y el
        # calificado (:N, :live): uno no cubre al otro. Van los dos.
        Resource = [aws_lambda_function.app.arn, "${aws_lambda_function.app.arn}:*"]
      },
      {
        Sid      = "LaAlarmaDeLaDemo"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:SetAlarmState"]
        Resource = aws_cloudwatch_metric_alarm.errores.arn
      },
      {
        # GetMetricStatistics entra en el millon de peticiones gratis al mes de
        # CloudWatch; GetMetricData se cobra desde la primera metrica.
        Sid      = "MetricasNoAdmitenArn"
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricStatistics"
        Resource = "*"
      },
      {
        Sid      = "DiagnosticosDelN1"
        Effect   = "Allow"
        Action   = "logs:FilterLogEvents"
        Resource = [aws_cloudwatch_log_group.oncall.arn, "${aws_cloudwatch_log_group.oncall.arn}:*"]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "web" {
  count             = var.web_enabled ? 1 : 0
  name              = "/aws/lambda/${local.web_name}"
  retention_in_days = 1
}

data "archive_file" "web" {
  count            = var.web_enabled ? 1 : 0
  type             = "zip"
  source_file      = "${path.module}/../src-web/control.py"
  output_path      = "${path.module}/.build/web.zip"
  output_file_mode = "0644"
}

resource "aws_lambda_function" "web" {
  count            = var.web_enabled ? 1 : 0
  function_name    = local.web_name
  description      = "Consola web de la demo: las manos del humano (el N1 sigue de solo lectura)"
  runtime          = "python3.12"
  handler          = "control.handler"
  role             = aws_iam_role.web[0].arn
  timeout          = 29 # el HTTP API corta a los 30 s
  memory_size      = 256
  filename         = data.archive_file.web[0].output_path
  source_code_hash = data.archive_file.web[0].output_base64sha256

  environment {
    variables = {
      APP_NAME         = aws_lambda_function.app.function_name
      ALARM_NAME       = aws_cloudwatch_metric_alarm.errores.alarm_name
      ONCALL_LOG_GROUP = aws_cloudwatch_log_group.oncall.name
      STABLE_VERSION   = terraform_data.version_estable.output
      DEMO_PIN         = random_password.pin[0].result
      # Para los enlaces a la consola de AWS de cada paso (sin el ID de cuenta) y los rotulos.
      APP_LOG_GROUP       = aws_cloudwatch_log_group.app.name
      ONCALL_NAME         = aws_lambda_function.oncall.function_name
      RULE_NAME           = aws_cloudwatch_event_rule.alarma.name
      SNS_TOPIC_NAME      = aws_sns_topic.incidentes.name
      WEB_NAME            = local.web_name
      MODEL_ID            = var.model_id
      FOUNDATION_MODEL_ID = var.foundation_model_id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.web,
    aws_iam_role_policy.web_logs,
    aws_iam_role_policy.web_manos,
  ]
}
