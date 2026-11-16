variable "region" {
  description = "AWS Region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "stage" {
  description = <<-EOT
    Which point of the week to build.
    "baseline": the weekly task as a first attempt, with one public website bucket that also holds the uploaded folders.
    "hardened": after the review, with the internal folders moved to a private, versioned bucket and a manual database snapshot taken.
  EOT
  type        = string
  default     = "hardened"

  validation {
    condition     = contains(["baseline", "hardened"], var.stage)
    error_message = "stage must be \"baseline\" or \"hardened\"."
  }
}

variable "vpc_cidr" {
  description = "Address range of the database VPC. It has no internet gateway."
  type        = string
  default     = "10.40.0.0/16"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is the smallest current class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL major version. AWS picks the minor version and keeps it patched."
  type        = string
  default     = "17"
}

variable "db_allocated_storage" {
  description = "RDS storage in GiB. 20 is the minimum for gp3."
  type        = number
  default     = 20

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 100
    error_message = "Keep the lab database between 20 and 100 GiB."
  }
}

variable "db_backup_retention_days" {
  description = "Days of automated RDS backups. 0 would switch backups off, so it is not allowed."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "Automated backups must stay on: use 1 to 35 days."
  }
}
