terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.52.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.4.3"
    }
  }
  required_version = ">= 1.1.0"

  cloud {
    organization = "hugo-organization"

    workspaces {
      name = "learn-terraform-github-actions"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "random_pet" "sg" {}

resource "random_password" "db_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "db_secret" {
  name = "mysql-rds-password-2"
}

resource "aws_secretsmanager_secret_version" "db_secret_version" {
  secret_id     = aws_secretsmanager_secret.db_secret.id
  secret_string = random_password.db_password.result
}

resource "aws_security_group" "rds-sg" {
  name = "${random_pet.sg.id}-rds-sg"

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "mysql" {
  identifier             = "fiap-mysql-db-2"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  username               = "admin"
  password               = random_password.db_password.result
  db_name                = "fiapdb"
  skip_final_snapshot    = true
  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.rds-sg.id]

  tags = {
    Name = "fiap-mysql-db"
  }
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.endpoint
}

# Create the Redis Security Group allowing access on port 6379 from anywhere
resource "aws_security_group" "redis_sg" {
  name_prefix = "redis_sg"

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow access from anywhere (make sure this is secure for your use case)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create the Redis Replication Group (for publicly accessible endpoint)
resource "aws_elasticache_replication_group" "redis_replication" {
  replication_group_id  = "fiap-redis-replication-group"
  description           = "Redis replication group for public access"
  engine                = "redis"
  node_type             = "cache.t3.micro"
  number_cache_clusters = 1 # Single-node setup (for this example)

  # Enable public access to the replication group
  # publicly_accessible = true

  security_group_ids = [aws_security_group.redis_sg.id]
  subnet_group_name  = aws_elasticache_subnet_group.redis_subnet_group.name

  tags = {
    Name = "fiap-redis-cluster"
  }
}

# Create the ElastiCache Redis Subnet Group
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "redis-subnet-group"
  subnet_ids = ["subnet-0e6be6f8c1d2d0232"]
}

# Output the Redis primary endpoint
output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis_replication.primary_endpoint
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "lambda.zip"

  source {
    content  = file("src/index.mjs")
    filename = "index.mjs"
  }
}

resource "aws_lambda_function" "http_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "cpf_auth_lambda"
  role             = "arn:aws:iam::174607920130:role/LabRole"
  handler          = "index.lambdaHandler"
  runtime          = "nodejs18.x"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DB_HOST     = split(":", aws_db_instance.mysql.endpoint)[0]
      DB_USER     = "admin"
      DB_PASSWORD = random_password.db_password.result
      DB_NAME     = "fiapdb"
      DB_PORT     = "3306"
      X_API_KEY   = "a60380f9-85d7-47bc-a73b-230cec5e4e1"
    }
  }
}

resource "aws_api_gateway_rest_api" "api" {
  name        = "cpf_auth_lambda_api"
  description = "API Gateway para Lambda HTTP"
}

resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "lambda"
}

resource "aws_api_gateway_method" "method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.resource.id
  http_method             = aws_api_gateway_method.method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.http_lambda.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.http_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "api" {
  depends_on  = [aws_api_gateway_integration.integration]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"
}

output "api_url" {
  value = aws_api_gateway_deployment.api.invoke_url
}