provider "aws" {
  region = "ap-south-1"
}

locals {
  cluster_name = "cluster1"
  k8s_version  = "1.35" # must match a version Canonical publishes an Ubuntu EKS AMI for (see note below)
  ubuntu_ver   = "24.04"
}

########################
# Cluster IAM role
########################
resource "aws_iam_role" "cluster1" {
  name = "eks-cluster-example987"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster1.name
}

########################
# Network (default VPC)
########################
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

########################
# EKS cluster
########################
resource "aws_eks_cluster" "cluster1" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster1.arn
  version  = local.k8s_version

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = data.aws_subnets.default.ids
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy
  ]
}

########################
# Worker node IAM role
########################
resource "aws_iam_role" "worker_nodes" {
  name = "eks-worker-node-role-example987"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.worker_nodes.name
}

########################
# Ubuntu AMI (Canonical official EKS image)
########################
data "aws_ssm_parameter" "ubuntu_eks_ami" {
  name = "/aws/service/canonical/ubuntu/eks/${local.ubuntu_ver}/${local.k8s_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

########################
# Launch template
########################
resource "aws_launch_template" "ubuntu_nodes" {
  name_prefix   = "eks-ubuntu-"
  image_id      = data.aws_ssm_parameter.ubuntu_eks_ami.value
  instance_type = "c7i-flex.large"

  # Custom AMI => you must supply the bootstrap yourself
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -ex
    /etc/eks/bootstrap.sh ${aws_eks_cluster.cluster1.name}
  EOF
  )

  block_device_mappings {
    device_name = "/dev/sda1" # Ubuntu root device
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # needed so pods can reach IMDS
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "eks-ubuntu-worker"
    }
  }
}

########################
# Managed node group (Ubuntu)
########################
resource "aws_eks_node_group" "worker_nodes" {
  cluster_name    = aws_eks_cluster.cluster1.name
  node_group_name = "worker-nodes-ubuntu"
  node_role_arn   = aws_iam_role.worker_nodes.arn
  subnet_ids      = data.aws_subnets.default.ids

  # Do NOT set ami_type / instance_types / disk_size here;
  # they come from the launch template.
  launch_template {
    id      = aws_launch_template.ubuntu_nodes.id
    version = aws_launch_template.ubuntu_nodes.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.worker_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.worker_AmazonEC2ContainerRegistryReadOnly
  ]
}

output "update_kubeconfig" {
  value = "aws eks update-kubeconfig --region ap-south-1 --name ${aws_eks_cluster.cluster1.name}"
}
