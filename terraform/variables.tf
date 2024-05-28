variable "org_id" {
  description = "Your Google Cloud organization ID number."
  default     = "null"
}

variable "project_id" {
  description = "The deployment project ID."
  default     = "null"
}

variable "billing_project" {
  description = "The billing project for your Google Cloud organization."
  default     = "null"
}

variable "region" {
  description = "The region for the deployment."
  default     = "null"
}

variable "zone" {
  description = "The zone within the deployment region."
  default     = "us-central1-a"
}
variable "prefix" {
  description = "A unique string to prepend to each created resource."
  default     = "panw"
}