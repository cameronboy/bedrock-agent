terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.48"
    }
    opensearch = {
      source  = "opensearch-project/opensearch"
      version = "= 2.2.0"
    }
  }
  required_version = "~> 1.5"
}

provider "opensearch" {
  url         = aws_opensearchserverless_collection.this.collection_endpoint
  healthcheck = false
}

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

data "aws_bedrock_foundation_model" "agent" {
  model_id = var.agent_model_id
}

data "aws_bedrock_foundation_model" "kb" {
  model_id = var.kb_model_id
}

data "aws_iam_policy" "lambda_basic_execution" {
  name = "AWSLambdaBasicExecutionRole"
}

locals {
  account_id            = data.aws_caller_identity.this.account_id
  partition             = data.aws_partition.this.partition
  region                = data.aws_region.this.name
  region_name_tokenized = split("-", local.region)
  region_short          = "${substr(local.region_name_tokenized[0], 0, 2)}${substr(local.region_name_tokenized[1], 0, 1)}${local.region_name_tokenized[2]}"
}

resource "aws_iam_role" "bedrock_kb" {
  name = "AmazonBedrockExecutionRoleForKnowledgeBase_${var.kb_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["sts:AssumeRole"],
        Effect = "Allow",
        Principal = {
          Service = "bedrock.amazonaws.com"
        },
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          },
          ArnLike = {
            "aws:SourceArn" = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:knowledge-base/*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_agent_kb_model" {
  name = "AmazonBedrockFoundationModelPolicyForKnowledgeBase_${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "bedrock:InvokeModel",
          "bedrock:GetModel"
        ]
        Effect   = "Allow"
        Resource = data.aws_bedrock_foundation_model.kb.model_arn
      }
    ]
  })
}

resource "aws_s3_bucket" "this" {
  bucket        = "${var.kb_s3_bucket_name_prefix}-${local.region_short}-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "this" {
  bucket = aws_s3_bucket.this.bucket
  key    = "motogp_2022_survey.pdf"
  source = "${path.module}/motogp_2022_survey.pdf"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agent_kb" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
  depends_on = [aws_s3_bucket_server_side_encryption_configuration.agent_kb]
}

resource "aws_iam_role_policy" "bedrock_kb_agent_kb_s3" {
  name = "AmazonBedrockS3PolicyForKnowledgeBase_${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ListBucketStatement"
        Action   = "s3:ListBucket"
        Effect   = "Allow"
        Resource = aws_s3_bucket.this.arn
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = local.account_id
          }
        }
      },
      {
        Sid      = "S3GetObjectStatement"
        Action   = "s3:GetObject"
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.this.arn}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_opensearchserverless_access_policy" "agent_kb" {
  name = var.kb_oss_collection_name
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "index"
          Resource = [
            "index/${var.kb_oss_collection_name}/*"
          ]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex", # Required for Terraform
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:UpdateIndex",
            "aoss:WriteDocument"
          ]
        },
        {
          ResourceType = "collection"
          Resource = [
            "collection/${var.kb_oss_collection_name}"
          ]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DescribeCollectionItems",
            "aoss:UpdateCollectionItems"
          ]
        }
      ],
      Principal = [
        aws_iam_role.bedrock_kb.arn,
        data.aws_caller_identity.this.arn
      ]
    }
  ])
}

resource "aws_opensearchserverless_security_policy" "agent_kb_encryption" {
  name = var.kb_oss_collection_name
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource = [
          "collection/${var.kb_oss_collection_name}"
        ]
        ResourceType = "collection"
      }
    ],
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "agent_kb_network" {
  name = var.kb_oss_collection_name
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "collection"
          Resource = [
            "collection/${var.kb_oss_collection_name}"
          ]
        },
        {
          ResourceType = "dashboard"
          Resource = [
            "collection/${var.kb_oss_collection_name}"
          ]
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_collection" "this" {
  name = var.kb_oss_collection_name
  type = "VECTORSEARCH"
  depends_on = [
    aws_opensearchserverless_access_policy.agent_kb,
    aws_opensearchserverless_security_policy.agent_kb_encryption,
    aws_opensearchserverless_security_policy.agent_kb_network
  ]
}

resource "aws_iam_role_policy" "bedrock_kb_agent_kb_oss" {
  name = "AmazonBedrockOSSPolicyForKnowledgeBase_${var.kb_name}"
  role = aws_iam_role.bedrock_kb.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "aoss:APIAccessAll"
        Effect   = "Allow"
        Resource = aws_opensearchserverless_collection.this.arn
      }
    ]
  })
}

resource "opensearch_index" "this" {
  name                           = "bedrock-knowledge-base-default-index"
  number_of_shards               = "2"
  number_of_replicas             = "0"
  index_knn                      = true
  index_knn_algo_param_ef_search = "512"
  mappings                       = <<-EOF
    {
      "properties": {
        "bedrock-knowledge-base-default-vector": {
          "type": "knn_vector",
          "dimension": 1536,
          "method": {
            "name": "hnsw",
            "engine": "faiss",
            "parameters": {
              "m": 16,
              "ef_construction": 512
            },
            "space_type": "l2"
          }
        },
        "AMAZON_BEDROCK_METADATA": {
          "type": "text",
          "index": "false"
        },
        "AMAZON_BEDROCK_TEXT_CHUNK": {
          "type": "text",
          "index": "true"
        }
      }
    }
  EOF
  force_destroy                  = true
  depends_on                     = [aws_opensearchserverless_collection.this]
}

resource "time_sleep" "aws_iam_role_policy_bedrock_kb_agent_kb_oss" {
  create_duration = "20s"
  depends_on      = [aws_iam_role_policy.bedrock_kb_agent_kb_oss]
}

resource "aws_bedrockagent_knowledge_base" "this" {
  name     = var.kb_name
  role_arn = aws_iam_role.bedrock_kb.arn
  knowledge_base_configuration {
    vector_knowledge_base_configuration {
      embedding_model_arn = data.aws_bedrock_foundation_model.kb.model_arn
    }
    type = "VECTOR"
  }
  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.this.arn
      vector_index_name = "bedrock-knowledge-base-default-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }
  depends_on = [
    aws_iam_role_policy.bedrock_kb_agent_kb_model,
    aws_iam_role_policy.bedrock_kb_agent_kb_s3,
    opensearch_index.this,
    time_sleep.aws_iam_role_policy_bedrock_kb_agent_kb_oss
  ]
}

resource "aws_bedrockagent_data_source" "this" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${var.kb_name}DataSource"
  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.this.arn
    }
  }
}

resource "aws_iam_role" "bedrock_agent_agent_asst" {
  name = "AmazonBedrockExecutionRoleForAgents_${var.agent_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:agent/*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_agent_agent_asst_model" {
  name = "AmazonBedrockAgentBedrockFoundationModelPolicy_${var.agent_name}"
  role = aws_iam_role.bedrock_agent_agent_asst.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "bedrock:InvokeModel"
        Effect   = "Allow"
        Resource = data.aws_bedrock_foundation_model.agent.model_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_agent_agent_asst_kb" {
  name = "AmazonBedrockAgentBedrockKnowledgeBasePolicy_${var.agent_name}"
  role = aws_iam_role.bedrock_agent_agent_asst.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "bedrock:Retrieve"
        Effect   = "Allow"
        Resource = aws_bedrockagent_knowledge_base.this.arn
      }
    ]
  })
}

resource "aws_bedrockagent_agent" "agent_asst" {
  agent_name              = var.agent_name
  agent_resource_role_arn = aws_iam_role.bedrock_agent_agent_asst.arn
  description             = var.agent_desc
  foundation_model        = data.aws_bedrock_foundation_model.agent.model_id
  instruction             = file("${path.module}/prompt_templates/agent_instruction.txt")
  depends_on = [
    aws_iam_role_policy.bedrock_agent_agent_asst_kb,
    aws_iam_role_policy.bedrock_agent_agent_asst_model
  ]
}

resource "aws_bedrockagent_agent_knowledge_base_association" "this" {
  agent_id             = aws_bedrockagent_agent.agent_asst.id
  description          = file("${path.module}/prompt_templates/kb_instruction.txt")
  knowledge_base_id    = aws_bedrockagent_knowledge_base.this.id
  knowledge_base_state = "ENABLED"
}

# data "archive_file" "agent_api_zip" {
#   type             = "zip"
#   source_file      = "${path.module}/lambda/agent_api/index.py"
#   output_path      = "${path.module}/tmp/agent_api.zip"
#   output_file_mode = "0666"
# }

# # Action group Lambda execution role
# resource "aws_iam_role" "lambda_agent_api" {
#   name = "FunctionExecutionRoleForLambda_${var.action_group_name}"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "lambda.amazonaws.com"
#         }
#         Condition = {
#           StringEquals = {
#             "aws:SourceAccount" = "${local.account_id}"
#           }
#         }
#       }
#     ]
#   })
#   managed_policy_arns = [data.aws_iam_policy.lambda_basic_execution.arn]
# }

# Action group Lambda function
# resource "aws_lambda_function" "agent_api" {
#   function_name = var.action_group_name
#   role          = aws_iam_role.lambda_agent_api.arn
#   description   = "A Lambda function for the action group ${var.action_group_name}"
#   filename      = data.archive_file.agent_api_zip.output_path
#   handler       = "index.lambda_handler"
#   runtime       = "python3.12"
#   # source_code_hash is required to detect changes to Lambda code/zip
#   source_code_hash = data.archive_file.agent_api_zip.output_base64sha256
#   depends_on       = [aws_iam_role.lambda_agent_api]
# }


# resource "aws_lambda_permission" "agent_api" {
#   action         = "lambda:invokeFunction"
#   function_name  = aws_lambda_function.agent_api.function_name
#   principal      = "bedrock.amazonaws.com"
#   source_account = local.account_id
#   source_arn     = "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:agent/*"
# }


# resource "aws_bedrockagent_agent_action_group" "agent_api" {
#   action_group_name          = var.action_group_name
#   agent_id                   = aws_bedrockagent_agent.agent_asst.id
#   agent_version              = "DRAFT"
#   description                = var.action_group_desc
#   skip_resource_in_use_check = true
#   action_group_executor {
#     lambda = aws_lambda_function.agent_api.arn
#   }
#   api_schema {
#     payload = file("${path.module}/lambda/agent_api/schema.yaml")
#   }
# }


# resource "null_resource" "agent_asst_prepare" {
#   triggers = {
#     # agent_api_state = sha256(jsonencode(aws_bedrockagent_agent_action_group.agent_api))
#     agent_kb_state = sha256(jsonencode(aws_bedrockagent_knowledge_base.this))
#   }
#   provisioner "local-exec" {
#     command = "aws bedrock-agent prepare-agent --agent-id ${aws_bedrockagent_agent.agent_asst.id}"
#   }
#   depends_on = [
#     aws_bedrockagent_agent.agent_asst,
#     # aws_bedrockagent_agent_action_group.agent_api,
#     aws_bedrockagent_knowledge_base.this
#   ]
# }
