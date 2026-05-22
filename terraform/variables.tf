variable "project_name" {
  description = "Tag + name prefix for all resources."
  type        = string
  default     = "iii"
}

variable "environment" {
  description = "Deployment environment (prod, dev, staging)."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to use."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to hit the public API on :80. Default open; tighten in tfvars."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_types" {
  description = "Per-role instance type."
  type = object({
    gateway          = string
    engine           = string
    caller_worker    = string
    inference_worker = string
  })
  default = {
    gateway          = "t3.small"
    engine           = "t3.small"
    caller_worker    = "t3.small"
    inference_worker = "t3.large"
  }
}

variable "enable_caller_worker" {
  description = "Provision the caller-worker VM. Set false to drop one instance."
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "OWNER/REPO that owns the OIDC trust for the deploy role."
  type        = string
}

variable "github_branch" {
  description = "Branch ref that the OIDC trust is scoped to."
  type        = string
  default     = "main"
}

variable "iii_release" {
  description = "Initial iii release tag baked into cloud-init. Overridden at runtime via SSM /iii/active_release."
  type        = string
  default     = "main"
}
