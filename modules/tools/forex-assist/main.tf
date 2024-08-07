# Use data sources to get common information about the environment
data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  partition  = data.aws_partition.this.partition
  region     = data.aws_region.this.name
}

data "aws_iam_policy" "lambda_basic_execution" {
  name = "AWSLambdaBasicExecutionRole"
}

# Action group Lambda execution role
resource "aws_iam_role" "lambda_forex_api" {
  name = "FunctionExecutionRoleForLambda_ForexAPI"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = "${local.account_id}"
          }
        }
      }
    ]
  })
  managed_policy_arns = [data.aws_iam_policy.lambda_basic_execution.arn]
}

data "archive_file" "forex_api_zip" {
  type             = "zip"
  source_file      = "${path.module}/lambda/forex_api/index.py"
  output_path      = "${path.module}/tmp/forex_api.zip"
  output_file_mode = "0666"
}

resource "aws_lambda_function" "forex_api" {
  function_name = "ForexAPI"
  role          = aws_iam_role.lambda_forex_api.arn
  description   = "A Lambda function for the forex API action group"
  filename      = data.archive_file.forex_api_zip.output_path
  handler       = "index.lambda_handler"
  runtime       = "python3.12"
  # source_code_hash is required to detect changes to Lambda code/zip
  source_code_hash = data.archive_file.forex_api_zip.output_base64sha256
}

resource "aws_lambda_permission" "forex_api" {
  action         = "lambda:invokeFunction"
  function_name  = aws_lambda_function.forex_api.function_name
  principal      = "bedrock.amazonaws.com"
  source_account = local.account_id
  source_arn     = "arn:aws:bedrock:${local.region}:${local.account_id}:agent/*"
}


resource "aws_bedrockagent_agent_action_group" "forex_api" {
  action_group_name          = "ForexAPI"
  agent_id                   = aws_bedrockagent_agent.forex_asst.id
  agent_version              = "DRAFT"
  description                = "The currency exchange rates API"
  skip_resource_in_use_check = true
  action_group_executor {
    lambda = aws_lambda_function.forex_api.arn
  }
  api_schema {
    payload = file("${path.module}/lambda/forex_api/schema.yaml")
  }
}