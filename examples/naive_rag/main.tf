locals {
  agent_name = "jeevs"
}

module "bedrock_agent_test" {
  source = "../../modules/bedrock-agent"
  #This is appended with region and account for uniqueness
  kb_s3_bucket_name_prefix = "${local.agent_name}-knowledge"
  # Open Search Collection
  kb_oss_collection_name = "bedrock-knowledge-base-${local.agent_name}-kb"
  #Embedding Model the knowledge base uses
  kb_model_id = "amazon.titan-embed-text-v1"
  #Arbitrary Knowledge base name
  kb_name = "${local.agent_name}KB"
  #llm used for the agent
  agent_model_id = "anthropic.claude-3-haiku-20240307-v1:0"
  agent_name     = "${local.agent_name}"
  agent_desc     = "An assistant that is general in Q/A"
}
