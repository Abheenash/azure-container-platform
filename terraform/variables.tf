variable "subscription_id" {
  description = "Azure subscription to deploy into. Required by azurerm v4+; no implicit default."
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralus"
}

variable "name_prefix" {
  description = "Name prefix for all resources"
  type        = string
  default     = "acp"

  validation {
    # Several Azure resource names (ACR, storage) are globally unique, alphanumeric
    # only, and short. Catching that here beats a failed apply 40 resources in.
    condition     = can(regex("^[a-z][a-z0-9]{1,10}$", var.name_prefix))
    error_message = "name_prefix must be 2-11 chars, lowercase alphanumeric, starting with a letter."
  }
}

variable "image_tag" {
  description = "Container image tag to run"
  type        = string
  default     = "v0.1.0"
}

variable "min_replicas" {
  description = "Container App minimum replicas. 0 enables scale-to-zero (and cold starts)."
  type        = number
  default     = 1
}

variable "max_replicas" {
  type    = number
  default = 4
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "github_repo" {
  description = "owner/repo allowed to federate into the deploy identity (keyless CI)"
  type        = string
  default     = "Abheenash/azure-container-platform"
}

variable "alert_email" {
  description = "Address that receives availability alerts. Empty disables the action group."
  type        = string
  default     = ""
}
