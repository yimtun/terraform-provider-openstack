## Credentials are variables with no defaults — an example file must never
## carry usable ones. Supply values through terraform.tfvars (gitignored) or
## TF_VAR_ environment variables.

variable "c1_user_name" { type = string }
variable "c1_password" {
  type      = string
  sensitive = true
}
variable "c1_project_id" { type = string }
variable "c1_user_domain" {
  type    = string
  default = "Default"
}

variable "c2_user_name" { type = string }
variable "c2_password" {
  type      = string
  sensitive = true
}
variable "c2_project_id" { type = string }
variable "c2_user_domain" {
  type    = string
  default = "Default"
}

variable "network_name" {
  description = "A network name that exists on both clusters, for read-only verification"
  type        = string
  default     = "private"
}

variable "cacert_file" {
  description = "Path to a private CA certificate (scenario E). Empty means use the system trust store"
  type        = string
  default     = ""
}
