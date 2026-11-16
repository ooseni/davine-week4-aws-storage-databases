# Two kinds of content, and the whole week turns on keeping them apart:
#   public   the static website (index.html, error.html, styles.css)
#   internal the uploaded folders: documents/, images/, logs/, backups/
#
# stage = "baseline"  one bucket holds both. Its public-read policy has to cover the website,
#                     and because it is written for the whole bucket it covers the folders too.
# stage = "hardened"  the folders live in a second bucket that blocks all public access, keeps
#                     versions, refuses plain HTTP and moves ageing objects to cheaper classes.

locals {
  site_files = {
    "index.html" = "text/html; charset=utf-8"
    "error.html" = "text/html; charset=utf-8"
    "styles.css" = "text/css; charset=utf-8"
  }

  # Each folder shows a different storage class, chosen by how the data is used.
  # All of it is synthetic: invented names, invented numbers.
  internal_files = {
    "documents/invoice-2026-08.txt" = { class = "STANDARD", type = "text/plain" }               # read often
    "documents/customer-export.csv" = { class = "STANDARD", type = "text/csv" }                 # read often
    "images/product-photo.svg"      = { class = "INTELLIGENT_TIERING", type = "image/svg+xml" } # access pattern unknown
    "logs/app-2026-08-24.log"       = { class = "STANDARD_IA", type = "text/plain" }            # rarely read, needed fast
    "backups/orders-2026-08-24.sql" = { class = "GLACIER_IR", type = "application/sql" }        # archive, still instant
  }

  # Where the internal folders live in each stage.
  internal_bucket = local.hardened ? one(aws_s3_bucket.data[*].bucket) : aws_s3_bucket.site.bucket
}

# --- Website bucket ---------------------------------------------------------------------------

#trivy:ignore:AVD-AWS-0089 Access logging is listed under Lab vs production
#trivy:ignore:AVD-AWS-0090 The website files are rebuilt from git
resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV_AWS_18:Access logging needs a third bucket that would outlive the lab. Listed under Lab vs production.
  #checkov:skip=CKV_AWS_144:Cross-Region replication is out of scope for a one-Region lab.
  #checkov:skip=CKV_AWS_145:SSE-S3 is used. A customer managed KMS key costs 1 USD a month, and anonymous website readers could not use it.
  #checkov:skip=CKV_AWS_21:The website files are rebuilt from git, so the site bucket is not versioned. The data bucket is.
  #checkov:skip=CKV2_AWS_61:Website files do not age. The data bucket has the lifecycle rule.
  #checkov:skip=CKV2_AWS_62:Event notifications have no consumer in this lab.
  #checkov:skip=CKV2_AWS_6:This bucket is the public website. Public ACLs are blocked. Public bucket policies must stay allowed for S3 website hosting.
  bucket        = "${local.name}-site-${random_id.suffix.hex}"
  force_destroy = true # a lab bucket must be removable in one terraform destroy

  tags = { Name = "${local.name}-site", DataClassification = "public" }
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs are switched off. Access is decided by policy alone.
  }
}

# S3 website hosting serves anonymous readers, so a public bucket policy has to be allowed here.
# ACL-based public access stays blocked.
#trivy:ignore:AVD-AWS-0087 A public bucket policy is what makes S3 website hosting work
#trivy:ignore:AVD-AWS-0093 A public bucket policy is what makes S3 website hosting work
resource "aws_s3_bucket_public_access_block" "site" {
  #checkov:skip=CKV_AWS_54:A public bucket policy is what makes S3 website hosting work.
  #checkov:skip=CKV_AWS_56:A public bucket policy is what makes S3 website hosting work.
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

#trivy:ignore:AVD-AWS-0132 SSE-S3 is used. Anonymous website readers could not use a KMS key
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

locals {
  site_arn = "arn:aws:s3:::${aws_s3_bucket.site.bucket}"

  site_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadForWebsite"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${local.site_arn}/*"
    }]
  })
}

resource "aws_s3_bucket_policy" "site" {
  #checkov:skip=CKV_AWS_70:Anonymous s3:GetObject is the purpose of the website bucket. No other action is granted.
  bucket = aws_s3_bucket.site.id
  policy = local.site_policy

  depends_on = [aws_s3_bucket_public_access_block.site, aws_s3_bucket_ownership_controls.site]
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket        = aws_s3_bucket.site.id
  key           = each.key
  source        = "${path.module}/site/${each.key}"
  source_hash   = filemd5("${path.module}/site/${each.key}")
  content_type  = each.value
  cache_control = "max-age=300"

  tags = { DataClassification = "public" }
}

# --- Data bucket (hardened stage only) --------------------------------------------------------

#trivy:ignore:AVD-AWS-0089 Access logging is listed under Lab vs production
resource "aws_s3_bucket" "data" {
  #checkov:skip=CKV_AWS_18:Access logging needs a third bucket that would outlive the lab. Listed under Lab vs production.
  #checkov:skip=CKV_AWS_144:Cross-Region replication is out of scope for a one-Region lab.
  #checkov:skip=CKV_AWS_145:SSE-S3 is used. A customer managed KMS key costs 1 USD a month. Listed under Lab vs production.
  #checkov:skip=CKV2_AWS_62:Event notifications have no consumer in this lab.
  count = local.hardened ? 1 : 0

  bucket        = "${local.name}-data-${random_id.suffix.hex}"
  force_destroy = true # removes every version too, so terraform destroy leaves nothing behind

  tags = { Name = "${local.name}-data", DataClassification = "internal" }
}

resource "aws_s3_bucket_ownership_controls" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132 SSE-S3 is used. A customer managed key is listed under Lab vs production
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    id     = "age-documents-to-cheaper-classes"
    status = "Enabled"

    filter {
      prefix = "documents/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "tidy-old-versions-and-failed-uploads"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

locals {
  data_arn = local.hardened ? "arn:aws:s3:::${aws_s3_bucket.data[0].bucket}" : ""

  data_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyRequestsWithoutTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.data_arn, "${local.data_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "data" {
  count  = local.hardened ? 1 : 0
  bucket = aws_s3_bucket.data[0].id
  policy = local.data_policy

  depends_on = [aws_s3_bucket_public_access_block.data, aws_s3_bucket_ownership_controls.data]
}

# --- The uploaded folders ---------------------------------------------------------------------
# One resource, two homes: the website bucket in the baseline, the data bucket once hardened.
# Changing the stage makes Terraform delete the objects from one bucket and create them in the other.

resource "aws_s3_object" "internal" {
  for_each = local.internal_files

  bucket        = local.internal_bucket
  key           = each.key
  source        = "${path.module}/sample-data/${each.key}"
  source_hash   = filemd5("${path.module}/sample-data/${each.key}")
  content_type  = each.value.type
  storage_class = each.value.class

  tags = { DataClassification = "internal" }

  depends_on = [aws_s3_bucket_versioning.data, aws_s3_bucket_ownership_controls.site]
}
