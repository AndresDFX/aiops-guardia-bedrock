# ═════════════════════════════════════════════════════════════
# SALIDAS (las mismas que el stack de CloudFormation)
# ═════════════════════════════════════════════════════════════
output "app_function_name" {
  description = "Servicio de demo que se va a romper"
  value       = aws_lambda_function.app.function_name
}

output "stable_version" {
  # Lambda NO reinicia la numeracion si recreas una funcion con el mismo nombre:
  # la primera version puede ser la 3 o la 7. El apply la deja tambien en
  # .version-estable, que es lo primero que lee restaurar.sh.
  description = "Version estable conocida de app-pagos (destino del rollback)"
  value       = terraform_data.version_estable.output
}

output "alarm_name" {
  description = "Alarma que dispara al ingeniero de guardia"
  value       = aws_cloudwatch_metric_alarm.errores.alarm_name
}

output "oncall_function_name" {
  description = "Lambda del ingeniero de guardia N1"
  value       = aws_lambda_function.oncall.function_name
}

output "oncall_log_group" {
  description = "Donde leer el diagnostico (aws logs tail ... --follow)"
  value       = aws_cloudwatch_log_group.oncall.name
}

output "incident_topic_arn" {
  description = "Topic SNS del incidente"
  value       = aws_sns_topic.incidentes.arn
}

output "event_rule_name" {
  description = "Regla de EventBridge alarma -> guardia"
  value       = aws_cloudwatch_event_rule.alarma.name
}

output "web_url" {
  description = "Consola web del incidente (CloudFront). La primera vez tarda unos minutos en responder."
  value       = var.web_enabled ? "https://${aws_cloudfront_distribution.web[0].domain_name}" : "sin consola web (web_enabled = false)"
}

output "web_pin" {
  description = "PIN de los botones de la consola. Lo imprime ./deploy.sh; tambien: terraform -chdir=terraform output -raw web_pin"
  value       = var.web_enabled ? random_password.pin[0].result : ""
  sensitive   = true
}

# Algunos pasos cambian si hay consola web. Van como texto aparte y no como %{if} dentro del
# heredoc: ahi la sangria de las lineas condicionales no se recorta igual que la del resto.
locals {
  paso_web = var.web_enabled ? join("\n", [
    "  4. O sigue el incidente y aprueba desde la consola web: https://${aws_cloudfront_distribution.web[0].domain_name}",
    "     CloudFront tarda 1-2 min en publicarla: si no abre, espera y recarga. El PIN lo imprime ./deploy.sh.",
  ]) : "  4. (Sin consola web. WEB=true ./deploy.sh la crea.)"
  paso_destroy = var.web_enabled ? join("\n", [
    "  6. Al terminar, borra todo: ./destroy.sh",
    "     (~3,5 min: CloudFront deshabilita la distribucion antes de borrarla)",
  ]) : "  6. Al terminar, borra todo: ./destroy.sh  (~15 s)"
}

output "siguientes_pasos" {
  description = "Que mirar ahora: lo imprime ./deploy.sh al final (y terraform apply, si despliegas a mano)"
  value = chomp(<<-EOT
    QUE MIRAR AHORA (desde la carpeta del repo):
      1. En una segunda columna de CloudShell (Actions -> Tabs layout -> Split into columns),
         deja corriendo la terminal del ingeniero de guardia: ./logs.sh
      2. Rompe produccion con un mal despliegue real: ./provocar_fallo.sh  (configuracion)
         o con un bug de codigo: ./provocar_fallo.sh codigo
         La alarma suena en 1-2 min y el diagnostico aparece en la columna de ./logs.sh.
      3. Leelo con ./ver_diagnostico.sh y, si estas de acuerdo, aprueba el rollback: ./aprobar.sh
    ${local.paso_web}
      5. Vuelve al estado sano con ./restaurar.sh. Despues, la falsa alarma: ./simular_alarma.sh
    ${local.paso_destroy}
  EOT
  )
}
