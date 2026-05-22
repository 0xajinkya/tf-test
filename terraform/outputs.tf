output "api_endpoint" {
  description = "Public HTTP endpoint for the iii API gateway."
  value       = "http://${aws_instance.gateway.public_ip}"
}

output "gateway_public_ip" {
  value = aws_instance.gateway.public_ip
}

output "gateway_instance_id" {
  value = aws_instance.gateway.id
}

output "engine_instance_id" {
  value = aws_instance.engine.id
}

output "inference_worker_instance_id" {
  value = aws_instance.inference_worker.id
}

output "caller_worker_instance_id" {
  value = try(aws_instance.caller_worker[0].id, null)
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.id
}

output "deploy_role_arn" {
  description = "Add this as AWS_ROLE_TO_ASSUME secret in GitHub."
  value       = aws_iam_role.deploy.arn
}

output "ssm_deploy_document" {
  value = aws_ssm_document.deploy.name
}

output "active_release_param" {
  value = aws_ssm_parameter.active_release.name
}
