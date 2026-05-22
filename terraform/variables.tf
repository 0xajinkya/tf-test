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

variable "github_branches" {
  description = "Branch refs allowed to assume the deploy role via OIDC. Add 'dev' when enabling stage."
  type        = list(string)
  default     = ["main"]
}

variable "github_environments" {
  description = "GitHub Environments allowed to assume the deploy role via OIDC. Add 'stage' when enabling stage."
  type        = list(string)
  default     = ["prod"]
}

variable "iii_release" {
  description = "Initial iii release tag baked into cloud-init. Overridden at runtime via SSM /iii/active_release."
  type        = string
  default     = "main"
}

variable "gguf_model_url" {
  description = "GGUF model download URL for llama.cpp. Default: TinyLlama 1.1B Chat Q4_K_M (~700MB)."
  type        = string
  default     = "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
}

variable "gguf_n_ctx" {
  description = "llama.cpp context window."
  type        = number
  default     = 2048
}

variable "api_keys_ssm_path" {
  description = "SSM Parameter Store path holding comma-separated API keys (SecureString)."
  type        = string
  default     = "/iii/api_keys"
}

variable "rate_limit_per_minute" {
  description = "Per-API-key requests/min (token bucket)."
  type        = number
  default     = 60
}
