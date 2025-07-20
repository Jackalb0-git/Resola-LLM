variable "aws_region" {
  type        = string
  default     = "ap-northeast-1"
  description = "Default region for deployment"
}

variable "postgres_db_name" {
  type    = string
  default = "litellmresola"
}

variable "postgres_username" {
  type = string
  default = "llmadmin"
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "litellm_image" {
  default = "732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest"
}

variable "litellm_master_key" {
  type        = string
  sensitive   = true
  description = "LiteLLM master key"
  default     = "sk-1234567890abcdefghijklm"
}

variable "litellm_config_file_path" {
  type        = string
  description = "Path to LiteLLM config file in container"
  default     = "/app/litellm-config.yaml"
}

variable "litellm_config_yaml" {
  type        = string
  description = "LiteLLM config YAML content"
  default     = "" 
}

variable "azure_api_base" {
  type        = string
  description = "Azure API base URL"
  default = "https://jacka-md8ldwnu-eastus2.openai.azure.com/"
}

variable "azure_api_key" {
  type        = string
  sensitive   = true
  description = "Azure API key"
}
