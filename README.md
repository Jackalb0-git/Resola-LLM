# Resola LLM Proxy Challenge

## Overview
This project deploys a LiteLLM proxy server on AWS using Terraform, designed to route API requests to an Azure OpenAI model (gpt-4o). The infrastructure is built for production-like reliability, including networking (VPC), compute (ECS Fargate), storage (RDS PostgreSQL for logs and user management, ElastiCache Redis for caching), load balancing (ALB), security (WAF, security groups), monitoring (CloudWatch alarms, SNS alerts, budgets), and auto-scaling. The proxy handles LLM requests securely, with features like master key authentication and robot blocking.

The deployment uses Terraform for IaC, Docker for containerization, and GitHub Actions for CI/CD. All sensitive data (e.g., API keys, DB passwords) is managed via AWS Secrets Manager. The total cost is controlled under $50/month with budgets.

**Key goals**:
- Support Azure OpenAI gpt-4o model.
- Handle high availability with auto-scaling.
- Ensure security and monitoring.
- Easy troubleshooting for common issues like 401 errors.

## Architecture
The architecture is designed as a multi-tier setup in AWS VPC, with public-facing components (ALB) in public subnets and backend services (ECS, RDS, Redis) in private subnets for security. Below is a detailed breakdown of components and their configurations:

- **VPC (Virtual Private Cloud)**:
  - Module: terraform-aws-modules/vpc/aws v6.0.1
  - Name: vpc-ap-northeast-1-prod-litellm
  - CIDR: 10.0.0.0/16
  - AZs: ap-northeast-1a, ap-northeast-1c, ap-northeast-1d
  - Private Subnets: 10.0.1.0/26, 10.0.1.64/26, 10.0.1.128/26 (for ECS, RDS, Redis)
  - Public Subnets: 10.0.2.0/26, 10.0.2.64/26, 10.0.2.128/26 (for ALB)
  - NAT Gateway: Enabled (single NAT with EIP for outbound from private subnets)
  - Tags: ApplicationName = "resolallmproxy"

- **ECS Cluster (Compute)**:
  - Module: terraform-aws-modules/ecs/aws v6.0.5
  - Name: ecs-ap-northeast-1-prod-litellm-cluster
  - Capacity Provider: FARGATE (weight 1, base 0)
  - Task Definition:
    - Family: ecs-task-ap-northeast-1-prod-litellm
    - CPU: 1024, Memory: 2048
    - Network Mode: awsvpc
    - Container: litellm-proxy (image from ECR: 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest)
    - Port: 8000
    - Environment Variables: REDIS_URL (from ElastiCache), LITELLM_CONFIG_FILE (/app/litellm-config.yaml), AZURE_API_BASE (hardcoded or from var)
    - Secrets: LITELLM_CONFIG, DATABASE_URL, AZURE_API_KEY, LITELLM_MASTER_KEY (from Secrets Manager)
    - Logs: CloudWatch group /ecs/litellm-ap-northeast-1
  - Service: ecs-service-ap-northeast-1-prod-litellm (desired count 1, FARGATE)
  - Auto-Scaling: AppAutoScaling target (min 1, max 2), policy for CPU >70%
  - IAM Roles: Execution role with Secrets Manager access, Task role
  - Tags: ApplicationName = "resolallmproxy"

- **RDS PostgreSQL (Database for Logs/User Management)**:
  - Engine: postgres v15
  - Instance Class: db.t3.micro
  - Storage: 20 GB
  - DB Name: litellmresola
  - Username: llmadmin
  - Password: Managed via Secrets Manager (postgres-password-ap-northeast-1-prod-litellm-v2)
  - Publicly Accessible: true (for local testing; set to false in production)
  - Subnet Group: db-subnet-group-ap-northeast-1-prod-litellm (private subnets; change to public for external access)
  - Security Group: Inbound TCP 5432 from ECS SG and your IP (e.g., 223.19.72.110/32)
  - Identifier: rds-ap-northeast-1-prod-litellm-postgres
  - Skip Final Snapshot: true
  - Tags: ApplicationName = "resolallmproxy"

- **ElastiCache Redis (Cache)**:
  - Engine: redis
  - Node Type: cache.t3.micro
  - Nodes: 1
  - Parameter Group: default.redis7
  - Subnet Group: elasticache-subnet-group-ap-northeast-1-prod-litellm (private subnets)
  - Security Group: Inbound TCP 6379 from ECS SG and your IP (e.g., 223.19.72.110/32)
  - Cluster ID: elasticache-ap-northeast-1-prod-litellm-redis
  - Tags: ApplicationName = "resolallmproxy"

- **ALB (Application Load Balancer)**:
  - Name: alb-ap-northeast-1-prod-litellm
  - Type: Application
  - Subnets: Public
  - Security Group: Inbound HTTP 80 from 0.0.0.0/0 (restrict to trusted IPs in production)
  - Target Group: tg-ap-northeast-1-prod-litellm (HTTP 8000, health check /health, interval 60s)
  - Listener: HTTP 80 forward to target group
  - WAF: Associated with AWSManagedRulesCommonRuleSet
  - Tags: ApplicationName = "resolallmproxy"

- **Secrets Manager**:
  - Secrets: litellm-config (YAML file), postgres-password, postgres-db-url (full DATABASE_URL), azure-api-key, litellm-master-key
  - IAM Policy: ECS execution role allows GetSecretValue for these ARNs

- **Monitoring & Alerts**:
  - CloudWatch: CPU alarm >80% on ECS, logs in /ecs/litellm-ap-northeast-1
  - SNS: Topic sns-ap-northeast-1-prod-litellm-alerts, email subscription resolallmproxy@outlook.com
  - Budget: $50/month cost limit with forecasted alerts

- **Other Components**:
  - ECR: litellm-proxy repo for Docker image
  - Route53: Zone resola-litellm.com
  - S3: Bucket s3-ap-northeast-1-prod-litellm-storage (versioned, private ACL)

- **Dockerfile Config**:
  - Base: python:3.10-slim
  - Install: litellm[proxy], prisma, Node.js for Prisma CLI
  - Entry point: Writes hard-coded config.yaml (model_list with Azure gpt-4o, general_settings with master key, etc.)
  - Expose: 8000

## Setup Steps
This section details all setup steps from initial configuration to deployment and testing. These steps build on each other, assuming you start from a clean environment.

1. **Clone Repository and Install Dependencies**:
   - Clone the repo: `git clone https://github.com/Jackalb0-git/resola.git && cd resola`.
   - Install Terraform: Download from terraform.io (v1.5+), add to PATH.
   - Install AWS CLI: `brew install awscli` (on macOS), configure with `aws configure` (access key, secret key, region ap-northeast-1).
   - Install Docker: Docker Desktop for macOS.
   - Initialize Git if new: `git init`, `git remote add origin https://github.com/Jackalb0-git/resola.git`.

2. **Configure Variables**:
   - Edit variables.tf:
     - aws_region: "ap-northeast-1"
     - postgres_db_name: "litellmresola"
     - postgres_username: "llmadmin"
     - postgres_password: Sensitive, set via tfvars or env (e.g., export TF_VAR_postgres_password="your_pass")
     - litellm_image: "732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest"
     - litellm_master_key: "sk-1234567890abcdefghijklm"
     - azure_api_base: "https://jacka-md8ldwnu-eastus2.openai.azure.com/"
     - azure_api_key: Sensitive, set via tfvars.
   - Create terraform.tfvars for sensitive vars (ignored in .gitignore):

3. **Terraform Initialization and Deployment**:
- Run `terraform init` to download modules/providers.
- Validate: `terraform validate`.
- Plan: `terraform plan -out=plan.tfout` (preview changes).
- Apply: `terraform apply plan.tfout` (deploy all resources: VPC, ECS, RDS, etc.).
- Wait 10-15 minutes for resources to provision (e.g., RDS may take time).
- Outputs: Check outputs.tf for vpc_id, subnet_ids, etc.

4. **Build and Push Docker Image**:
- Build: `docker build -t litellm-test .` (uses hard-coded config in entrypoint.sh).
- Login ECR: `aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com`.
- Tag: `docker tag litellm-test:latest 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest`.
- Push: `docker push 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest`.

5. **Update ECS Service**:
- Force new deployment: `aws ecs update-service --cluster ecs-ap-northeast-1-prod-litellm-cluster --service ecs-service-ap-northeast-1-prod-litellm --force-new-deployment --region ap-northeast-1`.
- Verify: `aws ecs describe-services --cluster ecs-ap-northeast-1-prod-litellm-cluster --services ecs-service-ap-northeast-1-prod-litellm --region ap-northeast-1` (check deployments running).

6. **Testing**:
- Get ALB DNS: From AWS Console > EC2 > Load Balancers > alb-ap-northeast-1-prod-litellm > DNS name.
- Health check: `curl http://<alb-dns>/health` (expect 200 OK).
- Model test: `curl -H "Authorization: Bearer sk-1234567890abcdefghijklm" http://<alb-dns>/v1/models`.
- Full API: `curl -X POST http://<alb-dns>/v1/chat/completions -H "Authorization: Bearer sk-1234567890abcdefghijklm" -H "Content-Type: application/json" -d '{"model": "gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}'`.

7. **Cleanup**:
- Destroy resources: `terraform destroy` (avoid ongoing costs).

## Troubleshooting
During development, several issues were encountered and resolved. Below is a detailed log of problems, symptoms, and fixes for reference.

- **401 Unauthorized Error (Most Common)**:
- **Symptoms**: curl /health or /v1/models returns 401, logs show "Authentication Error" or "No connected db".
- **Causes**: DB/Redis connection failure, invalid Azure key, master key missing in header, config.yaml not loaded.
- **Fixes**:
- Hardcode config in Dockerfile entrypoint.sh to bypass env vars/Secrets Manager.
- Verify Azure key: Direct curl to Azure endpoint (e.g., curl -X POST "https://jacka-md8ldwnu-eastus2.openai.azure.com/openai/deployments/gpt-4o-resola-llm/chat/completions?api-version=2024-10-21" -H "api-key: your_key" ...).
- Add master key header in curls.
- Bypass DB/Redis in config.yaml if not needed (remove database_url/redis_url).
- Update api_version to "2024-10-21" for compatibility.

- **DB Connection Timeout (P1001 Prisma Error)**:
- **Symptoms**: psql or Docker logs show "Can't reach database server", Operation timed out.
- **Causes**: RDS not publicly accessible, wrong subnet group (private instead of public), SG not allowing IP.
- **Fixes**:
- Set RDS publicly_accessible = true in main.tf.
- Change db_subnet_group to public subnets (add aws_db_subnet_group.public).
- Update SG inbound: Add your IP (e.g., cidr_blocks = ["your_ip/32"]) for port 5432.
- Test psql: `psql -h <endpoint> -p 5432 -U llmadmin -d litellmresola --set=sslmode=require`.
- Install psql if missing: `brew install libpq`, add to PATH.

- **Git Push File Size Limit Error**:
- **Symptoms**: Push fails with "file exceeds GitHub's file size limit of 100.00 MB" (e.g., terraform-provider-aws binary ~664 MB).
- **Causes**: .terraform/ directory committed (Terraform init downloads large binaries).
- **Fixes**:
- Add .gitignore to ignore .terraform/.
- Remove from staging: `git rm --cached -r .terraform/`.
- Re-commit and push.

- **ECR Push 401 Unauthorized**:
- **Symptoms**: Docker push fails with authentication error.
- **Causes**: AWS CLI not configured or credentials expired.
- **Fixes**: `aws configure` to set keys/region, re-run ECR login command.

- **Terraform Apply Errors**:
- **Symptoms**: Resource creation fails (e.g., RDS in wrong subnet).
- **Causes**: Config mismatches (e.g., private subnet with publicly_accessible=true).
- **Fixes**: Validate with `terraform validate`, plan first, update subnet groups.

- **Other Minor Issues**:
- AWS CLI Endpoint Error: Add --region ap-northeast-1 to commands.
- Prisma Generate Failure: Ensure DATABASE_URL env set correctly in Docker run.
- Config Not Loaded: Add debug log in entrypoint.sh to cat /app/litellm-config.yaml.

All issues were resolved by systematic debugging: checking logs (CloudWatch/Docker), verifying configs (Secrets Manager), and hardcoding for testing.

## CI/CD
A GitHub Actions workflow (.github/workflows/deploy.yaml) automates the deployment process on push to main:
- Checks out code.
- Configures AWS CLI with secrets.
- Builds Docker image.
- Pushes to ECR.
- Runs terraform init and apply.

**Workflow YAML**:
```yaml
name: Deploy to AWS

on:
push:
branches:
 - main

jobs:
deploy:
runs-on: ubuntu-latest
steps:
 - uses: actions/checkout@v4
 - name: Set up AWS CLI
   uses: aws-actions/configure-aws-credentials@v4
   with:
     aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
     aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
     aws-region: ap-northeast-1
 - name: Build Docker
   run: docker build -t litellm-test .
 - name: Push to ECR
   run: |
     aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com
     docker tag litellm-test:latest 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest
     docker push 732963826670.dkr.ecr.ap-northeast-1.amazonaws.com/litellm-proxy:latest
 - name: Terraform Apply
   run: |
     terraform init
     terraform apply -auto-approve