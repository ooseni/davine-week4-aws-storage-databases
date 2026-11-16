output "stage" {
  description = "baseline or hardened."
  value       = var.stage
}

output "region" {
  description = "AWS Region."
  value       = var.region
}

output "site_bucket" {
  description = "Name of the static website bucket."
  value       = aws_s3_bucket.site.bucket
}

output "data_bucket" {
  description = "Name of the private data bucket. Empty in the baseline stage."
  value       = local.hardened ? aws_s3_bucket.data[0].bucket : ""
}

output "internal_bucket" {
  description = "The bucket that holds the uploaded folders in this stage."
  value       = local.internal_bucket
}

output "website_url" {
  description = "S3 website endpoint (HTTP only)."
  value       = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}

output "internal_keys" {
  description = "Keys of the uploaded folders and the storage class each one should have."
  value       = { for k, v in local.internal_files : k => v.class }
}

output "vpc_id" {
  description = "Database VPC."
  value       = aws_vpc.main.id
}

output "db_subnet_ids" {
  description = "The two private subnets."
  value       = aws_subnet.db[*].id
}

output "db_security_group_id" {
  description = "Security group on the database."
  value       = aws_security_group.db.id
}

output "app_security_group_id" {
  description = "Security group the database accepts connections from."
  value       = aws_security_group.app.id
}

output "db_identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.main.identifier
}

output "db_address" {
  description = "RDS endpoint host name. It resolves to a private address."
  value       = aws_db_instance.main.address
}

output "db_snapshot_identifier" {
  description = "Manual snapshot taken in the hardened stage. Empty in the baseline."
  value       = local.hardened ? aws_db_snapshot.review[0].db_snapshot_identifier : ""
}

output "dynamodb_table" {
  description = "DynamoDB table name."
  value       = aws_dynamodb_table.carts.name
}
