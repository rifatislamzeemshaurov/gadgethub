# Data source to get current AWS account ID
data "aws_caller_identity" "current" {}

locals {
  fqdn = "${var.app_subdomain}.${var.domain_name}"

  aliases = var.use_custom_domain && var.domain_name != "" ? [local.fqdn] : []

  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ------------------------------------------------------------------------------
# S3 bucket for conversation memory
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "memory" {
  bucket = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "memory" {
  bucket = aws_s3_bucket.memory.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "memory" {
  bucket = aws_s3_bucket.memory.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ------------------------------------------------------------------------------
# S3 bucket for frontend static website
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# ------------------------------------------------------------------------------
# Networking — reuse the account's default VPC (no NAT gateway needed since
# Fargate tasks and the ALB both sit in public subnets with public IPs)
# ------------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# CloudFront's own IP range, so the ALB only accepts traffic that has gone
# through CloudFront — nobody can bypass it and hit the backend directly.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allow HTTP from CloudFront only"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_service" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "Allow the API container port from the ALB only"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.common_tags

  ingress {
    description     = "API port from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------------------------
# ECR — holds the backend's Docker image. Deploy scripts build/push here
# before the ECS task definition below references a tag.
# ------------------------------------------------------------------------------
resource "aws_ecr_repository" "backend" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# IAM — one role for ECS to pull the image / write logs, one for the running
# container's AWS access (S3 memory bucket only, not full access)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-execution-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_task_execution.name
}

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_s3_memory" {
  name = "${local.name_prefix}-ecs-task-s3-memory"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.memory.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.memory.arn}/*"]
      },
    ]
  })
}

# ------------------------------------------------------------------------------
# ECS — cluster, task definition, always-on Fargate service behind the ALB
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name_prefix}-api"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"
  tags = local.common_tags
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn
  tags                     = local.common_tags

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "CORS_ORIGINS", value = var.use_custom_domain ? "https://${local.fqdn}" : "https://${aws_cloudfront_distribution.main.domain_name}" },
        { name = "S3_BUCKET", value = aws_s3_bucket.memory.id },
        { name = "USE_S3", value = "true" },
        { name = "OPENAI_API_KEY", value = var.openai_api_key },
        { name = "OPENAI_MODEL", value = var.openai_model },
        { name = "QDRANT_URL", value = var.qdrant_url },
        { name = "QDRANT_API_KEY", value = var.qdrant_api_key },
        { name = "API_KEY_UI", value = var.api_key },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])
}

data "aws_region" "current" {}

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  tags               = local.common_tags
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name_prefix}-api-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  tags        = local.common_tags

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_ecs_service" "api" {
  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  tags            = local.common_tags

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.http]
}

# ------------------------------------------------------------------------------
# CloudFront — one distribution serves the static frontend (default behavior,
# S3 origin) and proxies the API paths (ordered behaviors, ALB origin) so the
# whole app lives on a single HTTPS domain with no CORS needed.
# ------------------------------------------------------------------------------

# When a custom domain is configured, that domain should be the canonical
# way the app is reached. CloudFront can't disable its own *.cloudfront.net
# domain (AWS doesn't offer that), so instead of a dead-end error this
# CloudFront Function 301-redirects any request whose Host header isn't the
# custom domain to the equivalent path/query on the custom domain — the
# production-standard pattern (frictionless UX, SEO canonicalization, and
# handled at the edge instead of spending ECS compute on it). Near-zero cost
# (CloudFront Functions have a large free tier) and adds no measurable
# latency. Attached to every cache behavior below.
#
# This only affects a human/browser navigating directly to the raw
# CloudFront URL — the frontend's own API calls always target the custom
# domain directly (see scripts/deploy.ps1 / deploy.sh), since redirecting a
# POST cross-origin is not something to rely on for the app's own fetches.
resource "aws_cloudfront_function" "host_guard" {
  count   = var.use_custom_domain ? 1 : 0
  name    = "${local.name_prefix}-host-guard"
  runtime = "cloudfront-js-2.0"
  comment = "301-redirect any request not addressed to ${local.fqdn}"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var host = request.headers.host && request.headers.host.value;
      if (host !== "${local.fqdn}") {
        var qs = "";
        for (var key in request.querystring) {
          qs += (qs ? "&" : "?") + key + "=" + request.querystring[key].value;
        }
        return {
          statusCode: 301,
          statusDescription: "Moved Permanently",
          headers: {
            "location": { value: "https://${local.fqdn}" + request.uri + qs },
            "cache-control": { value: "no-store" }
          }
        };
      }
      return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "main" {
  aliases = local.aliases

  viewer_certificate {
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate.site[0].arn : null
    cloudfront_default_certificate = var.use_custom_domain ? false : true
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  origin {
    domain_name = aws_s3_bucket_website_configuration.frontend.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.frontend.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALB-${local.name_prefix}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  tags                = local.common_tags

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400

    dynamic "function_association" {
      for_each = var.use_custom_domain ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_guard[0].arn
      }
    }
  }

  # API routes — proxied straight through to the ALB, caching disabled.
  ordered_cache_behavior {
    path_pattern     = "/chat"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${local.name_prefix}"

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    dynamic "function_association" {
      for_each = var.use_custom_domain ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_guard[0].arn
      }
    }
  }

  # PDF upload — same shape as /chat. Without this, POST /upload falls
  # through to the default behavior (S3, the frontend origin), which
  # answers a POST with a 405 XML error page instead of JSON, and the
  # frontend's response.json() throws — surfacing as a generic "could not
  # analyze that file" error with no indication it never reached the API.
  ordered_cache_behavior {
    path_pattern     = "/upload"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${local.name_prefix}"

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    dynamic "function_association" {
      for_each = var.use_custom_domain ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_guard[0].arn
      }
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/health"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${local.name_prefix}"

    forwarded_values {
      query_string = false
      headers      = ["*"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    dynamic "function_association" {
      for_each = var.use_custom_domain ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_guard[0].arn
      }
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/conversation/*"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${local.name_prefix}"

    forwarded_values {
      query_string = false
      headers      = ["*"]
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    dynamic "function_association" {
      for_each = var.use_custom_domain ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.host_guard[0].arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

# ------------------------------------------------------------------------------
# Optional: Custom subdomain configuration (only created when
# use_custom_domain = true) — serves the app at
# "${app_subdomain}.${domain_name}", e.g. rag.rifatai.com. The apex zone
# (domain_name) must already be a hosted zone in this account's Route 53.
# ------------------------------------------------------------------------------
data "aws_route53_zone" "root" {
  count        = var.use_custom_domain ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "site" {
  count             = var.use_custom_domain ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = local.fqdn
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
  tags = local.common_tags
}

resource "aws_route53_record" "site_validation" {
  for_each = var.use_custom_domain ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "site" {
  count           = var.use_custom_domain ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [
    for r in aws_route53_record.site_validation : r.fqdn
  ]
}

resource "aws_route53_record" "alias_app" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_app_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = local.fqdn
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
