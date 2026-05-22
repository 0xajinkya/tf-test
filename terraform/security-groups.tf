resource "aws_security_group" "gateway" {
  name        = "${local.name}-gateway"
  description = "Public iii HTTP gateway"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-gateway" }
}

resource "aws_security_group" "engine" {
  name        = "${local.name}-engine"
  description = "iii engine, WebSocket-only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-engine" }
}

resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "Workers - egress only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-worker" }
}

# Gateway: public :80 in, engine :9000 out.
resource "aws_vpc_security_group_ingress_rule" "gateway_http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public API ingress"
}

resource "aws_vpc_security_group_egress_rule" "gateway_to_engine" {
  security_group_id            = aws_security_group.gateway.id
  referenced_security_group_id = aws_security_group.engine.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  description                  = "Engine WebSocket"
}

resource "aws_vpc_security_group_egress_rule" "gateway_https" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "SSM, package installs"
}

# Engine: :9000 from gateway + workers. No outbound except HTTPS for install.
resource "aws_vpc_security_group_ingress_rule" "engine_from_gateway" {
  security_group_id            = aws_security_group.engine.id
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "engine_from_workers" {
  security_group_id            = aws_security_group.engine.id
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "engine_https" {
  security_group_id = aws_security_group.engine.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Workers: egress to engine + HTTPS only.
resource "aws_vpc_security_group_egress_rule" "worker_to_engine" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.engine.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "worker_https" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
