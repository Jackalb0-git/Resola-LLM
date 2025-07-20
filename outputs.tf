
output "vpc_id" {
 value = module.vpc.vpc_id
}

output "subnet_ids" {
 value = module.vpc.private_subnets
}

output "region" {
 value = var.aws_region
}

output "alb_sg_id" {
  value = aws_security_group.alb_sg.id
}