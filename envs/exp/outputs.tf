output "region" {
  value = var.region
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "instance_id" {
  value = aws_instance.beepee.id
}

output "results_bucket_name" {
  value = aws_s3_bucket.results.bucket
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.beepee.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.beepee.repository_url
}
