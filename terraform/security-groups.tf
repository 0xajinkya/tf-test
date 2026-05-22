resource "aws_security_group" "gateway" {
  name        = "${local.name}-gateway"
  description = "Public nginx reverse-proxy to engine iii-http"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-gateway" }
}

resource "aws_security_group" "engine" {
  name        = "${local.name}-engine"
  description = "iii engine + iii-http (49134 WS, 3111 HTTP)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-engine" }
}

resource "aws_security_group" "worker" {
  name        = "${local.name}-worker"
  description = "Workers - egress only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-worker" }
}

# ----- Gateway -----
resource "aws_vpc_security_group_ingress_rule" "gateway_http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Public API ingress"
}

resource "aws_vpc_security_group_egress_rule" "gateway_to_engine_http" {
  security_group_id            = aws_security_group.gateway.id
  referenced_security_group_id = aws_security_group.engine.id
  from_port                    = 3111
  to_port                      = 3111
  ip_protocol                  = "tcp"
  description                  = "Engine iii-http"
}

resource "aws_vpc_security_group_egress_rule" "gateway_https" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "SSM, package installs"
}

# ----- Engine -----
resource "aws_vpc_security_group_ingress_rule" "engine_http_from_gateway" {
  security_group_id            = aws_security_group.engine.id
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 3111
  to_port                      = 3111
  ip_protocol                  = "tcp"
  description                  = "iii-http from nginx"
}

resource "aws_vpc_security_group_ingress_rule" "engine_ws_from_workers" {
  security_group_id            = aws_security_group.engine.id
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 49134
  to_port                      = 49134
  ip_protocol                  = "tcp"
  description                  = "Engine WebSocket from workers"
}

resource "aws_vpc_security_group_egress_rule" "engine_https" {
  security_group_id = aws_security_group.engine.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ----- Workers -----
resource "aws_vpc_security_group_egress_rule" "worker_to_engine" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.engine.id
  from_port                    = 49134
  to_port                      = 49134
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "worker_https" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
