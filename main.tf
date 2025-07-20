terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.3.0" # 更新到最新版本
    }
  }
}

# Provider configuration for Tokyo region
provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    ApplicationName = "resolallmproxy"
  }
}

# VPC Module (Terraform Registry copy/modify)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0.1"

  name = "vpc-${var.aws_region}-prod-litellm"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}c", "${var.aws_region}d"]
  private_subnets = ["10.0.1.0/26", "10.0.1.64/26", "10.0.1.128/26"]
  public_subnets  = ["10.0.2.0/26", "10.0.2.64/26", "10.0.2.128/26"]
  external_nat_ip_ids = [aws_eip.nat_eip.id]
  enable_nat_gateway = true
  single_nat_gateway = true
  one_nat_gateway_per_az = false

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# ECS Cluster Module (Terraform Registry copy/modify)
module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 6.0.5"

  cluster_name = "ecs-${var.aws_region}-prod-litellm-cluster"

  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 1
      base   = 0
    }
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# RDS PostgreSQL (for LiteLLM database)
resource "aws_db_instance" "postgres" {
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  db_name                = var.postgres_db_name
  username               = var.postgres_username
  password               = aws_secretsmanager_secret_version.postgres_password_version.secret_string # 全用 Secrets Manager
  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  skip_final_snapshot    = true
  identifier             = "rds-${var.aws_region}-prod-litellm-postgres"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "db-subnet-group-${var.aws_region}-prod-litellm"
  subnet_ids = module.vpc.private_subnets

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# ElastiCache Redis (for cache)
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "elasticache-${var.aws_region}-prod-litellm-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "elasticache-subnet-group-${var.aws_region}-prod-litellm"
  subnet_ids = module.vpc.private_subnets

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# IAM Roles for ECS (execution and task)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "iam-role-${var.aws_region}-litellm-ecs-prod-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "iam-role-${var.aws_region}-prod-litellm-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# 添加 Secrets Manager 權限給 ECS Execution Role
resource "aws_iam_role_policy" "ecs_secrets_policy" {
  name = "ecs-secrets-access"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.litellm_config.arn,
          aws_secretsmanager_secret.postgres_db_url.arn,
          aws_secretsmanager_secret.postgres_password.arn,
          aws_secretsmanager_secret.azure_api_key.arn,
          aws_secretsmanager_secret.litellm_master_key.arn
        ]
      }
    ]
  })
}

# Security Groups
resource "aws_security_group" "ecs_sg" {
  name        = "security-group-${var.aws_region}-prod-litellm-ecs"
  description = "Allow inbound traffic from ALB for ECS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # 限制為 ALB
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_security_group" "db" {
  name   = "security-group-${var.aws_region}-prod-litellm-db"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["223.19.72.110/32"]  # 替換為你嘅 IP
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_security_group" "cache" {
  name   = "security-group-${var.aws_region}-prod-litellm-cache"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
    ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    cidr_blocks = ["223.19.72.110/32"]
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/litellm-${var.aws_region}"
  retention_in_days = 14

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# Secrets Manager for LiteLLM config YAML
resource "aws_secretsmanager_secret" "litellm_config" {
  name        = "litellm-config-${var.aws_region}-prod-v2"
  description = "LiteLLM configuration YAML file"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_secretsmanager_secret" "postgres_password" {
  name        = "postgres-password-${var.aws_region}-prod-litellm-v2"
  description = "PostgreSQL password for LiteLLM"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_secretsmanager_secret_version" "postgres_password_version" {
  secret_id     = aws_secretsmanager_secret.postgres_password.id
  secret_string = var.postgres_password
}

# Secrets Manager for entire DATABASE_URL
resource "aws_secretsmanager_secret" "postgres_db_url" {
  name        = "postgres-db-url-${var.aws_region}-prod-litellm-v2"
  description = "Full PostgreSQL DATABASE_URL for LiteLLM"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_secretsmanager_secret_version" "postgres_db_url_version" {
  secret_id     = aws_secretsmanager_secret.postgres_db_url.id
  secret_string = "postgresql://${var.postgres_username}:${aws_secretsmanager_secret_version.postgres_password_version.secret_string}@${aws_db_instance.postgres.endpoint}/${var.postgres_db_name}"
}

resource "aws_secretsmanager_secret_version" "litellm_config_version" {
  secret_id     = aws_secretsmanager_secret.litellm_config.id
  secret_string = file("litellm-config.yaml")
}

resource "aws_secretsmanager_secret" "azure_api_key" {
  name        = "azure-api-key-${var.aws_region}-prod-litellm"
  description = "Azure API key for LiteLLM"

  tags = {
    ApplicationName = "resolallmproxy"
  }
}

resource "aws_secretsmanager_secret_version" "azure_api_key_version" {
  secret_id     = aws_secretsmanager_secret.azure_api_key.id
  secret_string = var.azure_api_key  # 從 variables.tf 引用
}

resource "aws_secretsmanager_secret" "litellm_master_key" {
  name        = "litellm-master-key-${var.aws_region}-prod-litellm"
  description = "LiteLLM master key"

  tags = {
    ApplicationName = "resolallmproxy"
  }
}

resource "aws_secretsmanager_secret_version" "litellm_master_key_version" {
  secret_id     = aws_secretsmanager_secret.litellm_master_key.id
  secret_string = var.litellm_master_key  # 從 variables.tf 引用
}

# ECS Task Definition for resolallmproxy
resource "aws_ecs_task_definition" "litellm" {
  family                   = "ecs-task-${var.aws_region}-prod-litellm"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "litellm-proxy"
      image     = var.litellm_image
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
        }
      ]
      environment = [
        {
          name  = "REDIS_URL"
          value = "${aws_elasticache_cluster.redis.cache_nodes[0].address}:6379"
        },
        {
          name  = "LITELLM_CONFIG_FILE"
          value = var.litellm_config_file_path
        },
        {
          name      = "azure_api_base"
          valueFrom = var.azure_api_base
        }
      ]
      secrets = [
        {
          name      = "LITELLM_CONFIG"
          valueFrom = aws_secretsmanager_secret_version.litellm_config_version.arn
        },
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret_version.postgres_db_url_version.arn
        },
        {
          name      = "AZURE_API_KEY"
          valueFrom = aws_secretsmanager_secret_version.azure_api_key_version.arn
        },
        {
          name      = "LITELLM_MASTER_KEY"
          valueFrom = aws_secretsmanager_secret_version.litellm_master_key_version.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.litellm.name
          "awslogs-region"        = "${var.aws_region}"
          "awslogs-stream-prefix" = "litellm"
        }
      }
    }
  ])

  volume {
    name = "litellm-config"
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_ecr_repository" "litellm" {
  name = "litellm-proxy"
  tags = {
    ApplicationName = "resolallmproxy"
  }
}

# ECS Service
resource "aws_ecs_service" "litellm" {
  name            = "ecs-service-${var.aws_region}-prod-litellm"
  cluster         = module.ecs_cluster.cluster_id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "litellm-proxy"
    container_port   = 8000
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# Application Load Balancer (ALB) with SSL/TLS termination
resource "aws_lb" "alb" {
  name               = "alb-${var.aws_region}-prod-litellm"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_security_group" "alb_sg" {
  name   = "security-group-${var.aws_region}-prod-litellm-alb"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 考慮限制到可信 IP
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_lb_target_group" "litellm" {
  name        = "tg-${var.aws_region}-prod-litellm"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path = "/health" 
    interval            = 60  
    timeout             = 30  
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# HTTP listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_route53_zone" "main" {
  name = "resola-litellm.com"

  tags = {
    ApplicationName = "resolallmproxy"
  }
}


# Auto Scaling for ECS Service
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 2
  min_capacity       = 1
  resource_id        = "service/${module.ecs_cluster.cluster_name}/${aws_ecs_service.litellm.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_appautoscaling_policy" "scale_out" {
  name               = "scale-out-${var.aws_region}-prod-litellm"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70
  }
}

# S3 Bucket for file storage
resource "aws_s3_bucket" "storage" {
  bucket = "s3-ap-northeast-1-prod-litellm-storage"
  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

resource "aws_s3_bucket_versioning" "storage_versioning" {
  bucket = aws_s3_bucket.storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "storage_controls" {
  bucket = aws_s3_bucket.storage.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "storage_acl" {
  depends_on = [ aws_s3_bucket_ownership_controls.storage_controls ]
  bucket     = aws_s3_bucket.storage.id
  acl        = "private"
}

# SNS Topic for email alerts
resource "aws_sns_topic" "alert_topic" {
  name = "sns-${var.aws_region}-prod-litellm-alerts"

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# SNS Subscription for email
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.alert_topic.arn
  protocol  = "email"
  endpoint  = "resolallmproxy@outlook.com"
}

# Basic Monitoring: CloudWatch metric alarm
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "alarm-${var.aws_region}-prod-litellm-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS CPU exceeds 80%"
  dimensions = {
    ClusterName = module.ecs_cluster.cluster_name
    ServiceName = aws_ecs_service.litellm.name
  }
  alarm_actions = [aws_sns_topic.alert_topic.arn]

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# AWS Budget for $50 limit with email alert
resource "aws_budgets_budget" "cost_budget" {
  name         = "budget-${var.aws_region}-prod-litellm"
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["resolallmproxy@outlook.com"]
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# WAF Web ACL with managed rules for protection
resource "aws_wafv2_web_acl" "litellm_waf" {
  name        = "waf-${var.aws_region}-prod-litellm"
  description = "WAF for ALB protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "common-rules"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "commonRulesMetric"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "litellmWAFMetric"
  }

  tags = {
    ApplicationName    = "resolallmproxy"
  }
}

# Associate WAF to ALB
resource "aws_wafv2_web_acl_association" "alb_waf_association" {
  resource_arn = aws_lb.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.litellm_waf.arn
}