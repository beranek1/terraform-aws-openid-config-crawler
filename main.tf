terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

resource "aws_s3_bucket" "bucket" {
  count = var.dest_bucket_name == null ? 1 : 0

  bucket_prefix = replace("${var.prefix}bucket", "_", "-")

  force_destroy = true
}

locals {
  dest_bucket_name = var.dest_bucket_name == null ? aws_s3_bucket.bucket[0].id : var.dest_bucket_name
}

data "archive_file" "crawler" {
  type             = "zip"
  source_file      = "${path.module}/index.js"
  output_file_mode = "0666"
  output_path      = "${path.module}/crawler.zip"
}

data "aws_iam_policy_document" "crawler" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "${var.prefix}role"
  assume_role_policy = data.aws_iam_policy_document.crawler.json
}

resource "aws_iam_policy" "crawler" {
  name = "${var.prefix}policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:PutObject"]
        Effect   = "Allow"
        Resource = "arn:aws:s3:::${local.dest_bucket_name}/${var.dest_bucket_path}*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "crawler" {
  role       = aws_iam_role.crawler.name
  policy_arn = aws_iam_policy.crawler.arn
}

resource "aws_lambda_function" "crawler" {
  filename         = data.archive_file.crawler.output_path
  function_name    = "${var.prefix}function"
  role             = aws_iam_role.crawler.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.crawler.output_base64sha256
  runtime          = "nodejs16.x"
  timeout          = var.timeout

  environment {
    variables = {
      oidc_providers   = jsonencode(var.oidc_providers)
      dest_bucket_name = local.dest_bucket_name
      dest_bucket_path = var.dest_bucket_path
    }
  }
}

resource "aws_lambda_permission" "crawler" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.crawler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.crawler.arn
}

resource "aws_cloudwatch_event_rule" "crawler" {
  name                = "${var.prefix}rule"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "crawler" {
  rule = aws_cloudwatch_event_rule.crawler.name

  arn = aws_lambda_function.crawler.arn
}

resource "aws_lambda_invocation" "crawler" {
  function_name = aws_lambda_function.crawler.function_name

  triggers = {
    redeployment = sha1(jsonencode([
      aws_lambda_function.crawler.environment
    ]))
  }

  input = jsonencode({})
}

module "openid-jwks-crawler" {
  count = var.fetch_jwks ? 1 : 0

  source              = "beranek1/openid-jwks-crawler/aws"
  version             = ">=0.0.2"
  prefix              = "${var.prefix}jwks_"
  oidc_providers      = var.oidc_providers
  src_bucket_name     = local.dest_bucket_name
  src_bucket_path     = var.dest_bucket_path
  dest_bucket_name    = local.dest_bucket_name
  dest_bucket_path    = "${var.dest_bucket_path}jwks/"
  schedule_expression = var.schedule_expression
  timeout             = var.timeout

  # Make sure openid config crawler was executed atleast once
  depends_on = [
    aws_lambda_invocation.crawler
  ]
}
