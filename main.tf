provider "aws" {
  region = "ap-south-1"
}

variable "ssh_cidr" {
  description = "Your public IP address in CIDR format"
  type        = string
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_security_group" "k8s" {
  name   = "k8s-security-group"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    self        = true
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "k8s" {
  name = "k8s-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "k8s" {
  name = "k8s-ssm-policy"
  role = aws_iam_role.k8s.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:PutParameter",
        "ssm:GetParameter",
        "ssm:DeleteParameter"
      ]
      Resource = "arn:aws:ssm:ap-south-1:*:parameter/k8s-cluster/*"
    }]
  })
}

resource "aws_iam_instance_profile" "k8s" {
  name = "k8s-instance-profile"
  role = aws_iam_role.k8s.name
}

resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type           = "t3.medium"
  key_name                = "viraj"
  subnet_id               = data.aws_subnets.default.ids[0]
  vpc_security_group_ids  = [aws_security_group.k8s.id]
  iam_instance_profile    = aws_iam_instance_profile.k8s.name

  user_data = <<-EOF
#!/bin/bash
set -eux

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y containerd curl gpg apt-transport-https ca-certificates awscli

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

modprobe overlay
modprobe br_netfilter

cat <<EOT > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOT

cat <<EOT > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOT

sysctl --system

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

MASTER_IP=$(hostname -I | awk '{print $1}')

kubeadm init \
  --apiserver-advertise-address=$MASTER_IP \
  --pod-network-cidr=10.244.0.0/16

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

JOIN_COMMAND=$(kubeadm token create --print-join-command)

aws ssm put-parameter \
  --region ap-south-1 \
  --name "/k8s-cluster/join-command" \
  --type "String" \
  --value "$JOIN_COMMAND" \
  --overwrite

EOF

  tags = {
    Name = "K8s-Master"
  }

  depends_on = [
    aws_iam_role_policy.k8s
  ]
}

resource "aws_instance" "worker" {
  count = 2

  ami                    = data.aws_ami.ubuntu.id
  instance_type           = "t3.medium"
  key_name                = "viraj"
  subnet_id               = data.aws_subnets.default.ids[0]
  vpc_security_group_ids  = [aws_security_group.k8s.id]
  iam_instance_profile    = aws_iam_instance_profile.k8s.name

  user_data = <<-EOF
#!/bin/bash
set -eux

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y containerd curl gpg apt-transport-https ca-certificates awscli

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

modprobe overlay
modprobe br_netfilter

cat <<EOT > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOT

cat <<EOT > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOT

sysctl --system

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

for i in $(seq 1 60); do

  JOIN_COMMAND=$(aws ssm get-parameter \
    --region ap-south-1 \
    --name "/k8s-cluster/join-command" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true)

  if [[ "$JOIN_COMMAND" == sudo* ]]; then
    break
  fi

  sleep 20

done

if [[ "$JOIN_COMMAND" != sudo* ]]; then
  echo "ERROR: Master join command not available"
  exit 1
fi

eval "$JOIN_COMMAND"

EOF

  tags = {
    Name = "K8s-Worker-${count.index + 1}"
  }

  depends_on = [
    aws_instance.master,
    aws_iam_role_policy.k8s
  ]
}

output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}
