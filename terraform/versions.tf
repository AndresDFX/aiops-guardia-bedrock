# ═════════════════════════════════════════════════════════════
# VERSIONES
#   hashicorp/aws en su mayor actual (6), hashicorp/archive para
#   empaquetar las Lambdas sin bucket de despliegue y hashicorp/random
#   para el PIN de la consola web.
#   El .terraform.lock.hcl va en el repo: fija la version exacta de
#   cada provider y sus checksums, igual en CloudShell que en tu portatil.
# ═════════════════════════════════════════════════════════════
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  # CloudFormation marca sus recursos con el nombre del stack.
  # Aqui lo hacemos a proposito: todo lo que crea Terraform lleva estas etiquetas.
  default_tags {
    tags = {
      Proyecto      = var.project_name
      GestionadoPor = "terraform"
    }
  }
}
