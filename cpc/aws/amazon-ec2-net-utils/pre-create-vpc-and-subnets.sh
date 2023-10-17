#!/bin/bash

set -x

aws_region=$1
instance_type=$2
release=$3

# Create the VPC
vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region ${aws_region} --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $vpc_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-vpc

# Create the Public subnet
public_subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block 10.0.1.0/24 --region ${aws_region} --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $public_subnet_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-public-subnet

# Create the Private subnet
private_subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block 10.0.2.0/24 --region ${aws_region} --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $private_subnet_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-private-subnet

# Create Internet Gateway
igw_id=$(aws ec2 create-internet-gateway --region ${aws_region} --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $igw_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-internet-gw
aws ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id --region ${aws_region}

# Create NAT Gateway
nat_eip_alloc_id=$(aws ec2 allocate-address --domain vpc --region ${aws_region} --tag-specifications ResourceType=elastic-ip,Tags='[{Key=Name,Value="ec2-net-utils-vpc"}]' --query 'AllocationId' --output text)
natgw_id=$(aws ec2 create-nat-gateway --subnet-id $public_subnet_id --allocation-id $nat_eip_alloc_id --region ${aws_region} --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources $natgw_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-nat-gw
aws ec2 wait nat-gateway-available --nat-gateway-ids $natgw_id --region ${aws_region}

# Create Public Route Table
public_rt=$(aws ec2 create-route-table --vpc-id $vpc_id --region ${aws_region} --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $public_rt --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-public-rt
aws ec2 create-route --route-table-id $public_rt --destination-cidr-block 0.0.0.0/0 --gateway-id $igw_id --region ${aws_region}
aws ec2 associate-route-table --route-table-id $public_rt --subnet-id $public_subnet_id --region ${aws_region}

# Create Private Route Table
private_rt=$(aws ec2 create-route-table --vpc-id $vpc_id --region ${aws_region} --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $private_rt --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-private-rt
aws ec2 create-route --route-table-id $private_rt --destination-cidr-block 0.0.0.0/0 --gateway-id $natgw_id --region ${aws_region}
aws ec2 associate-route-table --route-table-id $private_rt --subnet-id $private_subnet_id --region ${aws_region}

# Create Security Group
secgroup_id=$(aws ec2 create-security-group --group-name ec2-net-utils-sg --description "Test ec2-net-utils" --vpc-id $vpc_id --region ${aws_region} --query 'GroupId' --output text)
aws ec2 create-tags --resources $secgroup_id --region ${aws_region} --tags Key=Name,Value=ec2-net-utils-sg
aws ec2 authorize-security-group-ingress --group-id $secgroup_id --protocol tcp --port 22 --cidr 0.0.0.0/0 --region ${aws_region}
aws ec2 authorize-security-group-ingress --group-id $secgroup_id --source-group $secgroup_id --cidr 0.0.0.0/0 --protocol -1 --region ${aws_region}

# Get ami_id
ami_id=$(aws ssm get-parameters --names /aws/service/canonical/ubuntu/server/$release/stable/current/amd64/hvm/ebs-gp2/ami-id --region ${aws_region} --query 'Parameters[].Value' --output text)

# Create the SSH key
ssh-keygen -t rsa -f ./ec2-net-utils-sshkey -q -N ""
aws ec2 import-key-pair --key-name ec2-net-utils-key --public-key-material fileb://./ec2-net-utils-sshkey.pub --region ${aws_region}

cat <<EOF > variables.sh
aws_region="$aws_region"
aws_instance_type="$instance_type"
aws_security_group="$secgroup_id"
aws_instance_name="amazon-ec2-net-utils-test"
aws_routerinstance_name="amazon-ec2-net-utils-router"
aws_subnet="$private_subnet_id"
aws_public_subnet="$public_subnet_id"
aws_vpc="$vpc_id"
aws_ami="$ami_id"
EOF
