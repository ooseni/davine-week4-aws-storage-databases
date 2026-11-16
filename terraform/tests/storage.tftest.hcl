# Design tests. The AWS provider is mocked, so these run in CI with no credentials and create
# nothing. They pin down the decisions that matter: what is public, what is private, what is
# backed up, and what changes between the baseline and the hardened stage.

mock_provider "aws" {}
mock_provider "random" {}

override_data {
  target = data.aws_availability_zones.available
  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "a1b2c3"
  }
}

variables {
  stage = "hardened"
}

# --- Website bucket ---------------------------------------------------------------------------

run "site_policy_grants_anonymous_get_object_and_nothing_else" {
  command = plan

  assert {
    condition     = length(jsondecode(local.site_policy).Statement) == 1
    error_message = "The website policy must have exactly one statement."
  }
  assert {
    condition     = jsondecode(local.site_policy).Statement[0].Action == "s3:GetObject"
    error_message = "Anonymous readers may only get objects: no list, put or delete."
  }
  assert {
    condition     = jsondecode(local.site_policy).Statement[0].Resource == "arn:aws:s3:::davine-wk4-site-a1b2c3/*"
    error_message = "The website policy must cover the site bucket's objects only."
  }
}

run "site_bucket_blocks_public_acls_but_allows_its_policy" {
  command = plan

  assert {
    condition     = aws_s3_bucket_public_access_block.site.block_public_acls && aws_s3_bucket_public_access_block.site.ignore_public_acls
    error_message = "Public ACLs must stay blocked on the website bucket."
  }
  assert {
    condition     = !aws_s3_bucket_public_access_block.site.block_public_policy && !aws_s3_bucket_public_access_block.site.restrict_public_buckets
    error_message = "S3 website hosting needs the public bucket policy to be allowed."
  }
}

run "site_serves_index_and_custom_error_document" {
  command = plan

  assert {
    condition     = aws_s3_bucket_website_configuration.site.index_document[0].suffix == "index.html"
    error_message = "The index document must be index.html."
  }
  assert {
    condition     = aws_s3_bucket_website_configuration.site.error_document[0].key == "error.html"
    error_message = "The error document must be error.html."
  }
}

run "site_objects_carry_content_types_a_browser_can_render" {
  command = plan

  assert {
    condition     = length(aws_s3_object.site) == 3
    error_message = "The website is three objects."
  }
  assert {
    condition     = startswith(aws_s3_object.site["index.html"].content_type, "text/html") && startswith(aws_s3_object.site["styles.css"].content_type, "text/css")
    error_message = "Without the right Content-Type a browser downloads the page instead of showing it."
  }
}

run "acls_are_disabled_on_both_buckets" {
  command = plan

  assert {
    condition     = aws_s3_bucket_ownership_controls.site.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be off on the site bucket."
  }
  assert {
    condition     = aws_s3_bucket_ownership_controls.data[0].rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be off on the data bucket."
  }
}

# --- Data bucket ------------------------------------------------------------------------------

run "data_bucket_blocks_all_public_access" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.data[0].block_public_acls,
      aws_s3_bucket_public_access_block.data[0].ignore_public_acls,
      aws_s3_bucket_public_access_block.data[0].block_public_policy,
      aws_s3_bucket_public_access_block.data[0].restrict_public_buckets,
    ])
    error_message = "All four Block Public Access settings must be on for the data bucket."
  }
}

run "data_bucket_keeps_versions" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.data[0].versioning_configuration[0].status == "Enabled"
    error_message = "Versioning is the improvement from the review. It must be Enabled."
  }
}

run "both_buckets_encrypt_at_rest" {
  command = plan

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.site.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The site bucket must encrypt with SSE-S3."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.data[0].rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The data bucket must encrypt with SSE-S3."
  }
}

run "data_policy_denies_requests_without_tls" {
  command = plan

  assert {
    condition     = jsondecode(local.data_policy).Statement[0].Effect == "Deny" && jsondecode(local.data_policy).Statement[0].Principal == "*"
    error_message = "The data bucket policy must be a Deny for everyone."
  }
  assert {
    condition     = jsondecode(local.data_policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "The Deny must apply when aws:SecureTransport is false."
  }
  assert {
    condition     = toset(jsondecode(local.data_policy).Statement[0].Resource) == toset(["arn:aws:s3:::davine-wk4-data-a1b2c3", "arn:aws:s3:::davine-wk4-data-a1b2c3/*"])
    error_message = "The Deny must cover the bucket and every object in it."
  }
  assert {
    condition     = length([for s in jsondecode(local.data_policy).Statement : s if s.Effect == "Allow"]) == 0
    error_message = "The data bucket policy must not allow anything."
  }
}

run "lifecycle_moves_documents_down_and_tidies_old_versions" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.data[0].rule) == 3
    error_message = "Three lifecycle rules are expected."
  }
  assert {
    condition     = [for t in aws_s3_bucket_lifecycle_configuration.data[0].rule[0].transition : "${t.days}:${t.storage_class}"] == ["30:STANDARD_IA", "90:GLACIER_IR"]
    error_message = "Documents move to Standard-IA at 30 days and Glacier Instant Retrieval at 90."
  }
  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.data[0].rule[2].noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "Old versions must expire, or versioning grows the bill for ever."
  }
  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.data[0].rule : r.status == "Enabled"])
    error_message = "Every lifecycle rule must be enabled."
  }
}

# --- The uploaded folders, in each stage ------------------------------------------------------

run "hardened_puts_the_folders_in_the_private_bucket" {
  command = plan

  assert {
    condition     = alltrue([for o in aws_s3_object.internal : o.bucket == "davine-wk4-data-a1b2c3"])
    error_message = "Once hardened, no internal object may be in the website bucket."
  }
  assert {
    condition     = toset([for k, o in aws_s3_object.internal : split("/", k)[0]]) == toset(["documents", "images", "logs", "backups"])
    error_message = "The uploads are organised into four folders."
  }
}

run "each_folder_uses_the_storage_class_chosen_for_it" {
  command = plan

  assert {
    condition = { for k, o in aws_s3_object.internal : k => o.storage_class } == {
      "documents/invoice-2026-08.txt" = "STANDARD"
      "documents/customer-export.csv" = "STANDARD"
      "images/product-photo.svg"      = "INTELLIGENT_TIERING"
      "logs/app-2026-08-24.log"       = "STANDARD_IA"
      "backups/orders-2026-08-24.sql" = "GLACIER_IR"
    }
    error_message = "A storage class changed. Update the report if that was intended."
  }
}

run "baseline_keeps_everything_in_the_one_public_bucket" {
  command = plan

  variables {
    stage = "baseline"
  }

  assert {
    condition     = length(aws_s3_bucket.data) == 0 && length(aws_s3_bucket_versioning.data) == 0
    error_message = "The baseline has no data bucket and no versioning."
  }
  assert {
    condition     = alltrue([for o in aws_s3_object.internal : o.bucket == "davine-wk4-site-a1b2c3"])
    error_message = "In the baseline the folders sit in the website bucket."
  }
  assert {
    condition     = length(aws_db_snapshot.review) == 0
    error_message = "The manual snapshot belongs to the review, not the baseline."
  }
  assert {
    condition     = output.data_bucket == "" && output.internal_bucket == "davine-wk4-site-a1b2c3"
    error_message = "Outputs must describe the baseline layout."
  }
}

run "an_unknown_stage_is_rejected" {
  command = plan

  variables {
    stage = "production"
  }

  expect_failures = [var.stage]
}

# --- Network ----------------------------------------------------------------------------------

run "database_subnets_are_private_and_in_two_zones" {
  command = plan

  assert {
    condition     = aws_subnet.db[*].availability_zone == ["us-east-1a", "us-east-1b"]
    error_message = "A DB subnet group needs subnets in two Availability Zones."
  }
  assert {
    condition     = aws_subnet.db[*].cidr_block == ["10.40.11.0/24", "10.40.12.0/24"]
    error_message = "Unexpected subnet ranges."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.db : !s.map_public_ip_on_launch])
    error_message = "Database subnets must not hand out public addresses."
  }
  assert {
    condition     = length(aws_route_table.db.route) == 0
    error_message = "The database route table must have the local route only: no internet or NAT gateway."
  }
}

run "database_accepts_postgresql_from_the_app_group_only" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_app.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_app.to_port == 5432
    error_message = "The only database port is 5432."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_app.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.db_from_app.cidr_ipv6 == null
    error_message = "The database rule must name a security group, never an address range."
  }
}

run "default_security_group_is_emptied" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.default.ingress) == 0 && length(aws_default_security_group.default.egress) == 0
    error_message = "The default security group must have no rules."
  }
}

# --- Amazon RDS -------------------------------------------------------------------------------

run "database_is_private_and_encrypted" {
  command = plan

  assert {
    condition     = !aws_db_instance.main.publicly_accessible
    error_message = "The database must not be publicly accessible."
  }
  assert {
    condition     = aws_db_instance.main.storage_encrypted && aws_db_instance.main.storage_type == "gp3"
    error_message = "Database storage must be encrypted gp3."
  }
  assert {
    condition     = aws_db_instance.main.engine == "postgres" && aws_db_instance.main.instance_class == "db.t4g.micro"
    error_message = "The lab database is PostgreSQL on db.t4g.micro."
  }
}

run "database_password_never_reaches_terraform" {
  command = plan

  assert {
    condition     = aws_db_instance.main.manage_master_user_password == true
    error_message = "RDS must manage the master password in Secrets Manager."
  }
  assert {
    condition     = aws_db_instance.main.password == null && aws_db_instance.main.password_wo == null
    error_message = "No password may be set in code."
  }
  assert {
    condition     = aws_db_instance.main.iam_database_authentication_enabled
    error_message = "IAM database authentication should be on."
  }
}

run "database_keeps_automated_backups_and_tags_its_snapshots" {
  command = plan

  assert {
    condition     = aws_db_instance.main.backup_retention_period == 7
    error_message = "Automated backups must be on."
  }
  assert {
    condition     = aws_db_instance.main.copy_tags_to_snapshot
    error_message = "Snapshots must inherit the instance's tags."
  }
}

run "switching_backups_off_is_rejected" {
  command = plan

  variables {
    db_backup_retention_days = 0
  }

  expect_failures = [var.db_backup_retention_days]
}

run "hardened_takes_a_manual_snapshot" {
  command = plan

  assert {
    condition     = aws_db_snapshot.review[0].db_snapshot_identifier == "davine-wk4-postgres-review"
    error_message = "The review stage takes one named manual snapshot."
  }
}

# --- Amazon DynamoDB --------------------------------------------------------------------------

run "cart_table_is_on_demand_with_a_composite_key" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.carts.billing_mode == "PAY_PER_REQUEST"
    error_message = "The table must be on-demand, so it costs nothing while idle."
  }
  assert {
    condition     = aws_dynamodb_table.carts.hash_key == "customer_id" && aws_dynamodb_table.carts.range_key == "sku"
    error_message = "A cart is keyed by customer, then by product."
  }
}

run "cart_table_has_point_in_time_recovery_and_ttl" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.carts.point_in_time_recovery[0].enabled
    error_message = "Point-in-time recovery must be on."
  }
  assert {
    condition     = aws_dynamodb_table.carts.ttl[0].enabled && aws_dynamodb_table.carts.ttl[0].attribute_name == "expires_at"
    error_message = "Abandoned carts expire through the expires_at TTL attribute."
  }
}

run "three_sample_cart_items_are_loaded" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table_item.sample) == 3
    error_message = "Three sample items are expected."
  }
  assert {
    condition     = jsondecode(aws_dynamodb_table_item.sample["CUST-1001/SKU-MUG"].item).quantity.N == "4"
    error_message = "Numbers must be stored as DynamoDB numbers."
  }
}
