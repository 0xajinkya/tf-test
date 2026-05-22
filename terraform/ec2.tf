data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  user_data_common_vars = {
    project_name    = var.project_name
    region          = var.region
    artifact_bucket = aws_s3_bucket.artifacts.id
    release         = var.iii_release
  }
}

# ---------- Gateway (public) ----------
resource "aws_instance" "gateway" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_types.gateway
  subnet_id                   = aws_subnet.public[var.azs[0]].id
  vpc_security_group_ids      = [aws_security_group.gateway.id]
  iam_instance_profile        = aws_iam_instance_profile.vm.name
  associate_public_ip_address = true

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data/gateway.sh.tftpl", merge(local.user_data_common_vars, {
    engine_http_endpoint = "http://${aws_instance.engine.private_ip}:3111"
  }))

  tags = {
    Name = "${local.name}-gateway"
    role = "gateway"
    app  = "iii"
  }

  depends_on = [aws_instance.engine, aws_nat_gateway.main, aws_vpc_endpoint.interface]
}

# ---------- Engine (private) ----------
resource "aws_instance" "engine" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_types.engine
  subnet_id              = aws_subnet.private[var.azs[0]].id
  vpc_security_group_ids = [aws_security_group.engine.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data/engine.sh.tftpl", local.user_data_common_vars)

  tags = {
    Name = "${local.name}-engine"
    role = "engine"
    app  = "iii"
  }

  depends_on = [aws_nat_gateway.main, aws_vpc_endpoint.interface]
}

# ---------- inference-worker (private) ----------
resource "aws_instance" "inference_worker" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_types.inference_worker
  subnet_id              = aws_subnet.private[var.azs[0]].id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data/inference-worker.sh.tftpl", merge(local.user_data_common_vars, {
    engine_endpoint = "ws://${aws_instance.engine.private_ip}:49134"
    gguf_model_url  = var.gguf_model_url
    gguf_n_ctx      = var.gguf_n_ctx
  }))

  tags = {
    Name = "${local.name}-inference-worker"
    role = "inference-worker"
    app  = "iii"
  }

  depends_on = [aws_instance.engine]
}

# ---------- caller-worker (private, optional) ----------
resource "aws_instance" "caller_worker" {
  count                  = var.enable_caller_worker ? 1 : 0
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_types.caller_worker
  subnet_id              = aws_subnet.private[var.azs[1 % length(var.azs)]].id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.vm.name

  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data/caller-worker.sh.tftpl", merge(local.user_data_common_vars, {
    engine_endpoint       = "ws://${aws_instance.engine.private_ip}:49134"
    api_keys_ssm_path     = var.api_keys_ssm_path
    rate_limit_per_minute = var.rate_limit_per_minute
  }))

  tags = {
    Name = "${local.name}-caller-worker"
    role = "caller-worker"
    app  = "iii"
  }

  depends_on = [aws_instance.engine]
}
