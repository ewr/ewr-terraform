# We need a cluster in which to put our service.
resource "aws_ecs_cluster" "ewr_is" {
  name = "ewr-is-prod"
}

# Log groups hold logs from our app.
resource "aws_cloudwatch_log_group" "ewr_is" {
  name = "/ecs/ewr-is-prod"
}

# The main service.
resource "aws_ecs_service" "ewr_is_app" {
  name            = "ewr-is-app"
  task_definition = aws_ecs_task_definition.ewr_is_app.arn
  cluster         = aws_ecs_cluster.ewr_is.id
  launch_type     = "FARGATE"
  enable_execute_command = true
  health_check_grace_period_seconds = 3600

  desired_count = 1

  load_balancer {
    target_group_arn = aws_lb_target_group.ewr_is_app.arn
    container_name   = "ewr-is-app"
    container_port   = "3000"
  }

  network_configuration {
    assign_public_ip = false

    security_groups = [
      aws_security_group.egress_all.id,
      aws_security_group.ingress_api.id,
    ]

    subnets = [
      aws_subnet.private_a.id,
      aws_subnet.private_b.id,
    ]
  }
}

resource "aws_ecs_service" "ewr_is_worker" {
    name = "ewr-is-worker"
    task_definition = aws_ecs_task_definition.ewr_is_worker.arn
    cluster = aws_ecs_cluster.ewr_is.id
    launch_type = "FARGATE"
    enable_execute_command = true

    desired_count = 1

    network_configuration {
      assign_public_ip = false

      security_groups = [
          aws_security_group.egress_all.id
      ]

      subnets = [
          aws_subnet.private_a.id,
          aws_subnet.private_b.id
      ]
    }
}

locals {
    common_container_definition = <<EOF
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-region": "us-east-2",
          "awslogs-group": "/ecs/ewr-is-prod",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "environment": [
          {
              "name": "MYSQL_HOST",
              "value": "${aws_db_instance.ewr_is.address}"
          },
          {
              "name": "MYSQL_DATABASE",
              "value": "${aws_db_instance.ewr_is.name}"
          },
          {
              "name": "MYSQL_USERNAME",
              "value": "ewr_is"
          },
          {
              "name": "REDIS_URI",
              "value": "redis://${aws_elasticache_cluster.ewr_is_redis.cache_nodes.0.address}/0"
          },
          {
              "name": "S3_BUCKET",
              "value": "ewr.is-assets-3"
          },
          {
              "name": "RAILS_ENV",
              "value": "production"
          },
          {
              "name": "S3_BUCKET_HOST_NAME",
              "value": "s3-us-east-2.amazonaws.com"
          },
          {
              "name": "QUEUE",
              "value": "assets"
          },
          {
              "name": "ASSETHOST_SERVER_URL",
              "value": "https://ewr.is"
          }
      ],
      "secrets": [
          {
              "name": "AWS_ACCESS_KEY_ID",
              "valueFrom": "arn:aws:ssm:us-east-2:822205560131:parameter/ewr_is/prod/s3_access_key"
          },
          {
              "name": "AWS_SECRET_KEY_ID",
              "valueFrom": "arn:aws:ssm:us-east-2:822205560131:parameter/ewr_is/prod/s3_secret_key"
          },
          {
              "name": "MYSQL_PASSWORD",
              "valueFrom": "arn:aws:ssm:us-east-2:822205560131:parameter/ewr_is/prod/mysql_password"
          }
      ]
    EOF
}

# The task definition for our app.
resource "aws_ecs_task_definition" "ewr_is_app" {
  family = "ewr-is-app"

  container_definitions = <<EOF
  [
    {
      "name": "ewr-is-app",
      "image": "822205560131.dkr.ecr.us-east-2.amazonaws.com/ewr-is-images:v1",
      "portMappings": [
        {
          "containerPort": 3000
        }
      ],
      ${local.common_container_definition}
    }
  ]
EOF

  execution_role_arn = aws_iam_role.ewr_is_task_execution_role.arn
  task_role_arn = aws_iam_role.ewr_is_task_role.arn

  cpu                      = 512
  memory                   = 2048
  requires_compatibilities = ["FARGATE"]

  # This is required for Fargate containers (more on this later).
  network_mode = "awsvpc"
}

resource "aws_ecs_task_definition" "ewr_is_worker" {
  family = "ewr-is-worker"

  container_definitions = <<EOF
  [
    {
      "name": "ewr-is-worker",
      "image": "822205560131.dkr.ecr.us-east-2.amazonaws.com/ewr-is-images:v1",
      "command": ["bundle", "exec", "rake", "resque:work"],
      "portMappings": [],
      ${local.common_container_definition}
    }
  ]
EOF

  execution_role_arn = aws_iam_role.ewr_is_task_execution_role.arn
  task_role_arn = aws_iam_role.ewr_is_task_role.arn

  cpu                      = 256
  memory                   = 1024
  requires_compatibilities = ["FARGATE"]

  # This is required for Fargate containers (more on this later).
  network_mode = "awsvpc"
}

# This is the role under which ECS will execute our task. This role becomes more important
# as we add integrations with other AWS services later on.

# The assume_role_policy field works with the following aws_iam_policy_document to allow
# ECS tasks to assume this role we're creating.
resource "aws_iam_role" "ewr_is_task_execution_role" {
  name               = "ewr-is-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  inline_policy {
      name = "ewr_is_parameters"

      policy = jsonencode({
          Statement = [
            {
                Effect: "Allow"
                Action: [
                    "ssm:GetParameters"
                ],
                Resource: "arn:aws:ssm:us-east-2:822205560131:parameter/ewr_is/*"
            }
          ]
      })
  }
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Normally we'd prefer not to hardcode an ARN in our Terraform, but since this is an AWS-managed
# policy, it's okay.
data "aws_iam_policy" "ecs_task_execution_role" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Attach the above policy to the execution role.
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role" {
  role       = aws_iam_role.ewr_is_task_execution_role.name
  policy_arn = data.aws_iam_policy.ecs_task_execution_role.arn
}

resource "aws_iam_role" "ewr_is_task_role" {
    name = "ewr-is-task-role"
    assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

    inline_policy {
      name = "ewr_is_ssm"

      policy = jsonencode({
          Statement = [
              {
                  Action = [
                      "ssmmessages:CreateControlChannel",
                      "ssmmessages:CreateDataChannel",
                      "ssmmessages:OpenControlChannel",
                      "ssmmessages:OpenDataChannel"
                  ]
                  Effect = "Allow"
                  Resource = "*"
              }
          ]
      })
    }
}

resource "aws_lb_target_group" "ewr_is_app" {
  name        = "ewr-is-app"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.app_vpc.id

  health_check {
    enabled = true
    path    = "/"
  }

  depends_on = [aws_alb.ewr_is]
}

resource "aws_alb" "ewr_is" {
  name               = "ewr-is-lb"
  internal           = false
  load_balancer_type = "application"

  subnets = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id,
  ]

  security_groups = [
    aws_security_group.http.id,
    aws_security_group.https.id,
    aws_security_group.egress_all.id,
  ]

  depends_on = [aws_internet_gateway.igw]
}

# resource "aws_alb_listener" "ewr_is_http_tmp" {
#     load_balancer_arn = aws_alb.ewr_is.arn
#     port = "80"
#     protocol = "HTTP"

#     default_action {
#         type = "forward"
#         target_group_arn = aws_lb_target_group.ewr_is_app.arn
#     }
# }

resource "aws_route53_zone" "ewr_is" {
    name = "ewr.is"
}

resource "aws_route53_record" "ewr_is_blog" {
    zone_id = aws_route53_zone.ewr_is.zone_id
    name = "blog.ewr.is"
    type = "A"

    alias {
        name = aws_alb.ewr_is.dns_name
        zone_id = aws_alb.ewr_is.zone_id
        evaluate_target_health = false
    }
}

resource "aws_route53_record" "ewr_is" {
    zone_id = aws_route53_zone.ewr_is.zone_id
    name = "ewr.is"
    type = "A"

    alias {
        name = aws_alb.ewr_is.dns_name
        zone_id = aws_alb.ewr_is.zone_id
        evaluate_target_health = false
    }
}

resource "aws_route53_record" "ewr_is_dkim" {
  zone_id = aws_route53_zone.ewr_is.zone_id
  name = "google._domainkey"
  type = "TXT"
  ttl = 300

  records = [
    "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmc79f8mBo8/rO7spZV3+Y9YZAV37iAT4q7lcr1cV650oIOZE5StyC2tO5I6ph/hls4u/yL1HZ30qJqry1W5QIQDGsmZByWmnBZn8DlHF/kazjSYJddkM71bss3n+L0cFuZDM/JuT4tvA8D2EcgRYkM5V06KObgNAmmhK/mNubm+Z+Ktml\"\"dLshBMzrutewz+OuKhlmUMJc3Bb/gJs6ZP+vEMSCPcWSQ7xJqUjcbCUQ1MkPNBcHw/mQmR0Z5jtCAZPj0cbepT+SlkAzW6iSFGbIBVLWGlUWvUPQEtzOh0u8BXxEjZsF0ohnXWeXJbUZoV+u7/Y0BQESg+0n8ESTyQwHQIDAQAB"
  ]
}

resource "aws_alb_listener" "ewr_is_http" {
  load_balancer_arn = aws_alb.ewr_is.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_alb_listener" "ewr_is_https" {
  load_balancer_arn = aws_alb.ewr_is.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.ewr_is.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ewr_is_app.arn
  }
}

output "alb_url" {
  value = "http://${aws_alb.ewr_is.dns_name}"
}

resource "aws_acm_certificate" "ewr_is" {
  domain_name       = "ewr.is"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
    for_each = {
        for dvo in aws_acm_certificate.ewr_is.domain_validation_options : dvo.domain_name => {
            name   = dvo.resource_record_name
            record = dvo.resource_record_value
            type   = dvo.resource_record_type
        }
    }

    allow_overwrite = true
    name            = each.value.name
    records         = [each.value.record]
    ttl             = 60
    type            = each.value.type

    zone_id = aws_route53_zone.ewr_is.zone_id
}

resource "aws_acm_certificate_validation" "ewr_is" {
    certificate_arn = aws_acm_certificate.ewr_is.arn

    validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}