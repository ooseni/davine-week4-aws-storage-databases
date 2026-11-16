# Credentials come from the environment (AWS_PROFILE with IAM Identity Center), never from code.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Only the first two zones by name are used (local.azs). A zone AWS adds later sorts after them, so the subnets do not move.
  state = "available"

  # Standard Availability Zones only: no Local Zones or Wavelength Zones.
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Bucket names are global. A random suffix keeps them unique without putting the account ID
# into a name that shows up in URLs and screenshots.
resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  name     = "davine-wk4"
  hardened = var.stage == "hardened"
  azs      = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  # Every resource gets these through default_tags, so cost, ownership and lifecycle are
  # visible in the console, in Cost Explorer and in any tag-based IAM condition.
  common_tags = {
    Project     = "davine-week4-aws-storage-databases"
    Programme   = "Davine Technologies internship"
    Environment = "lab"
    Owner       = "cloud-engineering"
    CostCenter  = "internship-labs"
    ManagedBy   = "terraform"
  }
}
