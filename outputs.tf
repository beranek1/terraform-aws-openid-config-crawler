output "dest_bucket_name" {
  value       = local.dest_bucket_name
  description = "Name of destination S3 bucket, usuful if input variable dest_bucket_name was omitted."
}
