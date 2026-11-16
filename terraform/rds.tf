# Amazon RDS for PostgreSQL: the relational side of the comparison. Private, encrypted, backed
# up every day, with a master password that Terraform never sees.

resource "aws_db_subnet_group" "main" {
  name        = "${local.name}-db-subnets"
  description = "Private subnets in two Availability Zones"
  subnet_ids  = aws_subnet.db[*].id

  tags = { Name = "${local.name}-db-subnets" }
}

#trivy:ignore:AVD-AWS-0133 Performance Insights is not needed for a database that serves no queries
#trivy:ignore:AVD-AWS-0177 Deletion protection would block terraform destroy. Listed under Lab vs production
resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_157:Single-AZ keeps the lab near free. Multi-AZ is listed under Lab vs production.
  #checkov:skip=CKV_AWS_293:Deletion protection would block terraform destroy. Listed under Lab vs production.
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds an IAM role and a log group that outlive the lab.
  #checkov:skip=CKV_AWS_129:Log exports leave CloudWatch log groups behind after destroy. Listed under Lab vs production.
  #checkov:skip=CKV_AWS_353:Performance Insights is not needed for a database that serves no queries.
  #checkov:skip=CKV2_AWS_30:Query logging needs a custom parameter group and log exports. Listed under Lab vs production.
  #checkov:skip=CKV2_AWS_69:PostgreSQL 15 and later on RDS set rds.force_ssl=1 by default. The live script checks it.
  identifier = "${local.name}-postgres"

  engine                     = "postgres"
  engine_version             = var.db_engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class

  # Storage is an encrypted gp3 EBS volume that RDS manages. This is where EBS appears this week.
  storage_type      = "gp3"
  allocated_storage = var.db_allocated_storage
  storage_encrypted = true # with the AWS managed key aws/rds, which has no monthly charge

  db_name  = "shop"
  username = "shop_admin"
  # RDS creates the password, stores it in Secrets Manager and rotates it. It never reaches
  # the Terraform state, a variable or this repository.
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "03:00-03:30"
  maintenance_window       = "sun:04:00-sun:04:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # Lab settings: the instance must be removable in one terraform destroy.
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true

  tags = { Name = "${local.name}-postgres", DataClassification = "internal" }
}

# The manual snapshot from the review. Unlike automated backups, a manual snapshot is kept until
# someone deletes it, so it survives the instance being deleted by mistake.
resource "aws_db_snapshot" "review" {
  count = local.hardened ? 1 : 0

  db_instance_identifier = aws_db_instance.main.identifier
  db_snapshot_identifier = "${local.name}-postgres-review"

  tags = { Name = "${local.name}-postgres-review" }
}
