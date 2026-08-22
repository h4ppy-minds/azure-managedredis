variable "env" {
  description = "Deployment environment for this TFC/pipeline workspace: dev, qa, uat, or prod. Selects which environments.<env> block in default.json applies, and filters onboarding request files to this environment only."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "qa", "uat", "prod"], var.env)
    error_message = "env must be one of: dev, qa, uat, prod."
  }
}
