# ═════════════════════════════════════════════════════════════
# VARIABLES (las mismas que los parametros de template.yaml,
# menos el bucket: aqui no hace falta)
# ═════════════════════════════════════════════════════════════
variable "region" {
  description = "Region de despliegue. La demo esta verificada en us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de todos los recursos. La regla de EventBridge escucha alarmas con este prefijo."
  type        = string
  default     = "guardia"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name: minusculas, numeros y guiones, empieza por letra, de 3 a 21 caracteres (igual que en template.yaml)."
  }
}

variable "model_id" {
  description = "Cross-region inference profile de Claude Sonnet 4.6 (prefijo us.). Desde us-east-1 enruta la peticion a us-east-1, us-east-2 o us-west-2 segun capacidad."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "foundation_model_id" {
  description = "ID del modelo base detras del perfil. Lo necesita la politica IAM. Si cambias model_id, cambia tambien este."
  type        = string
  default     = "anthropic.claude-sonnet-4-6"
}

variable "notification_email" {
  description = "(Opcional) Correo que recibe el diagnostico por SNS. Llega un correo de confirmacion."
  type        = string
  default     = ""
}

variable "web_enabled" {
  description = "Crea la consola web (bucket privado + CloudFront + HTTP API + Lambda de control, ver web.tf). Con false la demo es solo de terminal y el destroy no espera a CloudFront."
  type        = bool
  default     = true
}
