terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    # Configured via -backend-config or scripts/bootstrap-state.sh
    # bucket         = "iii-tf-state-<account-id>"
    # key            = "iii/prod/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "iii-tf-lock"
    # encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      environment = var.environment
      managed_by  = "terraform"
    }
  }
}
