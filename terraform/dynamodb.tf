# Amazon DynamoDB: the key-value side of the comparison. A shopping cart is read and written by
# one key (the customer), needs no joins, and should disappear on its own when abandoned.

#trivy:ignore:AVD-AWS-0025 Encrypted at rest with the AWS owned key. A customer managed key is listed under Lab vs production
resource "aws_dynamodb_table" "carts" {
  #checkov:skip=CKV_AWS_119:Encrypted at rest with the AWS owned key, which is free. A customer managed key is listed under Lab vs production.
  #checkov:skip=CKV2_AWS_16:On-demand capacity scales by itself. Auto scaling applies to provisioned capacity only.
  name         = "${local.name}-carts"
  billing_mode = "PAY_PER_REQUEST" # no capacity to guess, and no charge while idle
  hash_key     = "customer_id"
  range_key    = "sku"

  attribute {
    name = "customer_id"
    type = "S"
  }

  attribute {
    name = "sku"
    type = "S"
  }

  # Abandoned carts delete themselves: DynamoDB removes an item after its expires_at time.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Continuous backups: the table can be restored to any second in the last 35 days.
  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = false # lab setting, so terraform destroy works

  tags = { Name = "${local.name}-carts", DataClassification = "internal" }
}

locals {
  sample_cart_items = {
    "CUST-1001/SKU-KETTLE" = { customer_id = "CUST-1001", sku = "SKU-KETTLE", quantity = 1, unit_price_cents = 2499 }
    "CUST-1001/SKU-MUG"    = { customer_id = "CUST-1001", sku = "SKU-MUG", quantity = 4, unit_price_cents = 650 }
    "CUST-1002/SKU-LAMP"   = { customer_id = "CUST-1002", sku = "SKU-LAMP", quantity = 1, unit_price_cents = 3900 }
  }
}

resource "aws_dynamodb_table_item" "sample" {
  for_each = local.sample_cart_items

  table_name = aws_dynamodb_table.carts.name
  hash_key   = aws_dynamodb_table.carts.hash_key
  range_key  = aws_dynamodb_table.carts.range_key

  item = jsonencode({
    customer_id = { S = each.value.customer_id }
    sku         = { S = each.value.sku }
    quantity    = { N = tostring(each.value.quantity) }
    # Money as whole cents. DynamoDB normalises numbers ("6.50" comes back as "6.5"), which made
    # Terraform see a change on every plan when the price was written with trailing zeros.
    unit_price_cents = { N = tostring(each.value.unit_price_cents) }
    expires_at       = { N = "1924992000" } # 1 January 2031, far enough ahead that TTL leaves the samples alone
  })
}
