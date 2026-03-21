output "asg_name" {
  description = "Auto Scaling Group name (use to find the running instance)"
  value       = aws_autoscaling_group.ood.name
}

output "web_url" {
  description = "Web URL for the OOD portal"
  value = (
    var.enable_cdn && var.enable_alb ? "https://${aws_cloudfront_distribution.ood[0].domain_name}" :
    var.enable_alb && var.domain_name != "" ? "https://${var.domain_name}" :
    var.enable_alb ? "https://${aws_lb.ood[0].dns_name}" :
    var.domain_name != "" ? "https://${var.domain_name}" :
    "(no public URL — use SSM to connect and retrieve the instance IP)"
  )
}

output "alb_dns_name" {
  description = "ALB DNS name (empty if ALB is disabled)"
  value       = var.enable_alb ? aws_lb.ood[0].dns_name : ""
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain name (empty if CDN is disabled)"
  value       = var.enable_cdn && var.enable_alb ? aws_cloudfront_distribution.ood[0].domain_name : ""
}

output "efs_id" {
  description = "EFS file system ID for /home (empty if EFS is disabled)"
  value       = var.enable_efs ? aws_efs_file_system.home[0].id : ""
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (empty if Cognito is disabled)"
  value       = var.use_cognito ? aws_cognito_user_pool.ood[0].id : ""
  sensitive   = true # M7: pool IDs are not secrets but masked to prevent log leakage
}

output "cognito_app_client_id" {
  description = "Cognito App Client ID for OOD OIDC configuration"
  value       = var.use_cognito ? aws_cognito_user_pool_client.ood[0].id : ""
  sensitive   = true # M7
}

output "cognito_oidc_issuer" {
  description = "OIDC issuer URL (Cognito User Pool endpoint)"
  value = (
    var.use_cognito
    ? "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.ood[0].id}"
    : ""
  )
  sensitive = true # M7: contains pool ID
}

output "dynamodb_uid_table" {
  description = "DynamoDB UID mapping table name (empty if disabled)"
  value       = var.enable_dynamodb_uid ? aws_dynamodb_table.uid_map[0].name : ""
  sensitive   = true # M7
}

output "batch_job_queue_arn" {
  description = "AWS Batch job queue ARN (empty if Batch adapter not enabled)"
  value       = local.enable_batch ? aws_batch_job_queue.ood[0].arn : ""
  sensitive   = true # M7
}

output "sagemaker_domain_id" {
  description = "SageMaker Domain ID (empty if SageMaker adapter not enabled)"
  value       = local.enable_sagemaker ? aws_sagemaker_domain.ood[0].id : ""
  sensitive   = true # M7
}

output "s3_browser_bucket" {
  description = "S3 file browser bucket name (empty if disabled)"
  value       = var.enable_s3_browser ? aws_s3_bucket.ood_files[0].id : ""
  sensitive   = true # M7
}

output "acm_certificate_validation_cname" {
  description = "ACM DNS validation CNAME record — add to your DNS provider"
  value = (
    var.enable_alb && var.acm_certificate_arn == "" && var.domain_name != ""
    ? tomap({
      for dvo in aws_acm_certificate.ood[0].domain_validation_options :
      dvo.domain_name => {
        name  = dvo.resource_record_name
        type  = dvo.resource_record_type
        value = dvo.resource_record_value
      }
    })
    : {}
  )
}

output "ssm_connect_command" {
  description = "Command to find the running OOD instance and connect via SSM Session Manager"
  value       = "aws ec2 describe-instances --filters 'Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.ood.name}' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text | xargs -I{} aws ssm start-session --target {}"
}

output "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms (empty if monitoring disabled)"
  value       = var.enable_monitoring ? aws_sns_topic.ood[0].arn : ""
}

output "kms_key_arn" {
  description = "KMS CMK ARN (empty if KMS CMK disabled)"
  value       = var.enable_kms_cmk ? aws_kms_key.ood[0].arn : ""
  sensitive   = true # M7
}

output "oidc_client_secret_arn" {
  description = "Secrets Manager ARN holding the Cognito OIDC client secret (empty if Cognito disabled)"
  # L4: mark sensitive — the ARN itself is not a secret but knowing it enables targeted
  # GetSecretValue attempts and is a privilege escalation stepping stone.
  value     = var.use_cognito ? aws_secretsmanager_secret.oidc_client_secret[0].arn : ""
  sensitive = true
}
