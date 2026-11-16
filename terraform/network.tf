# A VPC for the database only: two private subnets in two Availability Zones, no internet
# gateway and no NAT gateway. Nothing in it can be reached from, or reach, the internet.

#trivy:ignore:AVD-AWS-0178 VPC flow logs would leave a log group behind after the lab. Week 3 covers them
resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:VPC flow logs would leave a log group behind after the lab. Week 3 covers them.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "db" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 11 + count.index) # 10.40.11.0/24, 10.40.12.0/24
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "data" }
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  route  = [] # the local route only: Terraform removes any other route it finds

  tags = { Name = "${local.name}-db-rt" }
}

resource "aws_route_table_association" "db" {
  count = 2

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# The default security group allows members to talk to each other. Emptied, so anything that
# lands in it by accident can talk to nothing.
resource "aws_default_security_group" "default" {
  vpc_id  = aws_vpc.main.id
  ingress = []
  egress  = []

  tags = { Name = "${local.name}-default-sg-no-rules" }
}

# The application tier's group. No instance uses it in this lab. It exists so the database rule
# can name "the application" instead of an address range.
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:No application instance runs in this lab. The group exists so the database rule can name its only allowed source.
  name        = "${local.name}-app-sg"
  description = "Application tier. The only source the database accepts."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "PostgreSQL from the application tier only. No outbound rules."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the application tier"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
