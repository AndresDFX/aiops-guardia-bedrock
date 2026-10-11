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
  description = "PIN de los botones de la consola. Se lee con: terraform -chdir=terraform output -raw web_pin"
  value       = var.web_enabled ? random_password.pin[0].result : ""
  sensitive   = true
}

# Los ultimos pasos cambian si hay consola web. Van como lista y no como %{if} dentro del
# heredoc: ahi la sangria de las lineas condicionales no se recorta igual que la del resto.
locals {
  pasos_finales = var.web_enabled ? join("\n", [
    "  4. O hazlo desde la consola web: https://${aws_cloudfront_distribution.web[0].domain_name}",
    "     CloudFront tarda unos minutos en publicarla: si no abre, espera y recarga.",
    "     Los botones piden un PIN: terraform -chdir=terraform output -raw web_pin",
    "  5. Al terminar, borra todo: terraform -chdir=terraform destroy",
    "     (con la consola tarda unos minutos mas: CloudFront deshabilita la distribucion antes de borrarla)",
  ]) : "  4. Al terminar, borra todo: terraform -chdir=terraform destroy"
}

output "siguientes_pasos" {
  description = "Que mirar ahora (lo mismo que imprime deploy.sh, mas la consola web si web_enabled)"
  value = chomp(<<-EOT
    QUE MIRAR AHORA:
      1. Estado de la alarma (debe decir OK o INSUFFICIENT_DATA):
         aws cloudwatch describe-alarms --alarm-names ${aws_cloudwatch_metric_alarm.errores.alarm_name} --query 'MetricAlarms[0].StateValue' --output text
      2. En otra terminal, deja corriendo los logs del ingeniero de guardia
         (sin las dos lineas JSON largas, que guardan el contexto y el diagnostico):
         aws logs tail ${aws_cloudwatch_log_group.oncall.name} --follow --format short --filter-pattern '-"CONTEXTO_JSON" -"DIAGNOSTICO_JSON"'
      3. Cuando quieras romper produccion, desde la raiz del repo: ./provocar_fallo.sh
    ${local.pasos_finales}
  EOT
  )
}
