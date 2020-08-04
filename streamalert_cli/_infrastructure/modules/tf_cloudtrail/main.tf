// KMS key for encrypting CloudTrail logs
resource "aws_kms_key" "cloudtrail_encryption" {
  description         = "Encrypt CloudTrail logs for ${var.s3_bucket_name}"
  policy              = data.aws_iam_policy_document.cloudtrail_encryption.json
  enable_key_rotation = true

  tags = {
    Name    = "StreamAlert"
    Cluster = var.cluster
  }
}

// This policy is auto-generated by AWS if you manually encrypt a CloudTrail from the console.
data "aws_iam_policy_document" "cloudtrail_encryption" {
  statement {
    sid = "Enable IAM User Permissions"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.primary_account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid = "Allow CloudTrail to encrypt logs"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${var.primary_account_id}:trail/*"]
    }
  }

  statement {
    sid = "Allow CloudTrail to describe key"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["kms:DescribeKey"]
    resources = ["*"]
  }

  statement {
    sid = "Allow principals in the account to decrypt log files"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "kms:Decrypt",
      "kms:ReEncryptFrom",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.primary_account_id]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${var.primary_account_id}:trail/*"]
    }
  }
}

resource "aws_kms_alias" "cloudtrail_encryption" {
  name          = "alias/${var.prefix}-${var.cluster}-streamalert-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail_encryption.key_id
}

// StreamAlert CloudTrail, optionally sending to CloudWatch Logs group
resource "aws_cloudtrail" "streamalert" {
  name                          = var.s3_bucket_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail_bucket.id
  cloud_watch_logs_role_arn     = var.cloudwatch_logs_role_arn  // defaults to null
  cloud_watch_logs_group_arn    = var.cloudwatch_logs_group_arn // defaults to null
  sns_topic_name                = var.send_to_sns ? aws_sns_topic.cloudtrail[0].name : null
  enable_log_file_validation    = true
  enable_logging                = var.enable_logging
  include_global_service_events = true
  is_multi_region_trail         = var.is_global_trail
  kms_key_id                    = aws_kms_key.cloudtrail_encryption.arn

  // Using this syntax allow for disabling the s3 event selector altogether if desired
  dynamic "event_selector" {
    for_each = var.s3_event_selector_type == "" ? [] : [1]
    content {
      read_write_type           = var.s3_event_selector_type
      include_management_events = true

      data_resource {
        type = "AWS::S3::Object"

        values = [
          "arn:aws:s3",
        ]
      }
    }
  }

  tags = {
    Name    = "StreamAlert"
    Cluster = var.cluster
  }
}

// S3 bucket for CloudTrail output
resource "aws_s3_bucket" "cloudtrail_bucket" {
  bucket        = var.s3_bucket_name
  policy        = data.aws_iam_policy_document.cloudtrail_bucket.json
  force_destroy = false

  versioning {
    enabled = true
  }

  logging {
    target_bucket = var.s3_logging_bucket
    target_prefix = "${var.s3_bucket_name}/"
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.cloudtrail_encryption.key_id
      }
    }
  }

  tags = {
    Name    = var.s3_bucket_name
    Cluster = var.cluster
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket" {

  statement {
    sid = "AWSCloudTrailAclCheck"

    actions = [
      "s3:GetBucketAcl",
    ]

    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid = "AWSCloudTrailWrite"

    actions = [
      "s3:PutObject",
    ]

    resources = formatlist(
      "arn:aws:s3:::${var.s3_bucket_name}/AWSLogs/%s/*",
      var.s3_cross_account_ids,
    )

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"

      values = [
        "bucket-owner-full-control",
      ]
    }
  }

  # Force SSL access only
  statement {
    sid = "ForceSSLOnlyAccess"

    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

// Replace any noncompliant characters with hyphens for the topic name
locals {
  sanitized_topic_name = replace(var.s3_bucket_name, "/[^a-zA-Z0-9_-]/", "-")
}

resource "aws_sns_topic" "cloudtrail" {
  count = var.send_to_sns ? 1 : 0

  name = local.sanitized_topic_name
}

// SNS topic policy document for cloudtrail to sns
resource "aws_sns_topic_policy" "cloudtrail" {
  count = var.send_to_sns ? 1 : 0

  arn    = aws_sns_topic.cloudtrail[0].arn
  policy = data.aws_iam_policy_document.cloudtrail[0].json
}

data "aws_iam_policy_document" "cloudtrail" {
  count = var.send_to_sns ? 1 : 0

  statement {
    sid    = "AWSCloudTrailSNSPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["SNS:Publish"]

    resources = [
      aws_sns_topic.cloudtrail[0].arn,
    ]

    dynamic "condition" {
      for_each = var.allow_cross_account_sns ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:SourceAccount"

        values = var.s3_cross_account_ids
      }
    }
  }
}
