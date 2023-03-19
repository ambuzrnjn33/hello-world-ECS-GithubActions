provider "aws" {
    region = "us-east-2"
}

# Create VPC
resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"

    tags = {
        Name = "my-demo-vpc"
    }
}

data "aws_availability_zones" "available" {
    state = "available"
}

# Create public subnets
resource "aws_subnet" "public" {
    count = 2

    cidr_block = "10.0.${4 + count.index * 2}.0/24"
    vpc_id = aws_vpc.main.id
    availability_zone = data.aws_availability_zones.available.names[count.index]

    tags = {
        Name = "my-demo-public-subnet-${count.index + 1}"
    }
}

# Create internet gateway
resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id

    tags = {
        Name = "my-demo-igw"
    }
}

# Create route table for public subnets
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }

    tags = {
        Name = "my-demo-public-rt"
    }
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
    count = 2
    subnet_id = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

resource "aws_iam_role" "ecs_task_execution" {
    name = "ecs-task-execution"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Principal = {
                    Service = "ecs-tasks.amazonaws.com"
                }
                Action = "sts:AssumeRole"
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    role = aws_iam_role.ecs_task_execution.name
}

#Create ECS task definition
resource "aws_ecs_task_definition" "app" {
    family = "my-demo-app"
    execution_role_arn = aws_iam_role.ecs_task_execution.arn
    task_role_arn = aws_iam_role.ecs_task_execution.arn
    network_mode = "awsvpc"
    container_definitions = jsonencode([
        {
            name = "my-demo-app"
            image = "ambuzrnjn33/demo-interview-app:latest"
            portMappings = [
                {
                    containerPort = 3000
                    hostPort = 3000
                    protocol = "tcp"
                }
            ]
        }
    ])
    requires_compatibilities = ["FARGATE"]

    memory = "2048"
    cpu = "1024"
}

# Create ECS Cluster
resource "aws_ecs_cluster" "app" {
    name = "my-demo-app-cluster"
}

# Create security groups for ECS tasks
resource "aws_security_group" "app" {
    name_prefix = "my-demo-app-"
    vpc_id = aws_vpc.main.id

    ingress {
        from_port = 3000
        to_port = 3000
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# Create security group for ALB
resource "aws_security_group" "alb" {
    name_prefix = "my-demo-alb-"
    vpc_id = aws_vpc.main.id

    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

#Create ALB
resource "aws_lb" "app" {
    name_prefix = "demoa-"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.alb.id]
    subnets = aws_subnet.public.*.id
}

# Create target groups for ALB
resource"aws_lb_target_group" "app" {
    name_prefix = "demoTG"
    port = 3000
    protocol = "HTTP"
    vpc_id = aws_vpc.main.id
    target_type = "ip"
    health_check {
        path = "/"
    }
}      

# Create ALB listener
resource "aws_lb_listener" "app" {
    load_balancer_arn = aws_lb.app.arn
    port = 80
    protocol = "HTTP"

    default_action {
        type= "forward"
        target_group_arn = aws_lb_target_group.app.arn
    }
}

# Create ECS service
resource "aws_ecs_service" "app" {
    name = "my-demo-app-service"
    cluster = aws_ecs_cluster.app.id
    task_definition = aws_ecs_task_definition.app.arn
    desired_count = 1
    launch_type = "FARGATE"

    network_configuration {
        subnets = aws_subnet.public.*.id
        security_groups = [aws_security_group.app.id]
        assign_public_ip = true
    }

    load_balancer {
        target_group_arn = aws_lb_target_group.app.arn
        container_name = "my-demo-app"
        container_port = 3000
    }

    depends_on = [aws_lb_listener.app]
}

output "load_balancer_url" {
    value = aws_lb.app.dns_name
    description = "The DNS name of the Application Load Balancer"
}