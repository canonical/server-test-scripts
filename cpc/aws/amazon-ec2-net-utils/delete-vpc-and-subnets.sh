#!/bin/bash

set -x

aws_region=$1

# Delete Security Group
secgroup_id=$(aws ec2 describe-security-groups --region ${aws_region} --filters Name=group-name,Values=ec2-net-utils-sg --query 'SecurityGroups[].GroupId' --output text)
aws ec2 delete-security-group --region ${aws_region} --group-id $secgroup_id

# Get VPC ID
vpc_id=$(aws ec2 describe-vpcs --region ${aws_region} --filters Name=tag:Name,Values=ec2-net-utils-vpc --query 'Vpcs[].VpcId' --output text)

# Remove route table association
for rtbassoc in $(aws ec2 describe-route-tables --region ${aws_region} --filters Name=vpc-id,Values=$vpc_id --query 'RouteTables[?Associations[0].Main != `true`].Associations[].RouteTableAssociationId'  --output text); do aws ec2 disassociate-route-table --region ${aws_region} --association-id $rtbassoc; done

# Delete NAT Gateway
natgw_id=$(aws ec2 describe-nat-gateways --region ${aws_region} --filter Name=tag:Name,Values=ec2-net-utils-nat-gw --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text)
aws ec2 delete-nat-gateway --region ${aws_region} --nat-gateway-id $natgw_id
aws ec2 wait nat-gateway-deleted --region ${aws_region} --nat-gateway-ids $natgw_id

# Delete Subnets
for subnet in `aws ec2 describe-subnets --region ${aws_region} --filter Name=vpc-id,Values=$vpc_id --query 'Subnets[].SubnetId'  --output text`; do aws ec2 delete-subnet --region ${aws_region} --subnet-id $subnet; done

# Delete Internet Gateway
igw_id=$(aws ec2 describe-internet-gateways --region ${aws_region} --filters "Name=attachment.vpc-id,Values=$vpc_id" --query 'InternetGateways[].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway --region ${aws_region} --internet-gateway-id $igw_id --vpc-id $vpc_id
aws ec2 delete-internet-gateway --region ${aws_region} --internet-gateway-id $igw_id 

# Delete route tables
for rt in $(aws ec2 describe-route-tables --region ${aws_region} --filters Name=vpc-id,Values=$vpc_id --query 'RouteTables[?Associations[0].Main != `true`].RouteTableId' --output text); do aws ec2 delete-route-table --route-table-id $rt --region ${aws_region}; done

# Finally delete the VPC
aws ec2 delete-vpc --region ${aws_region} --vpc-id $vpc_id

# Release the EIP
alloc_id=$(aws ec2 describe-addresses --region ${aws_region} --filters Name=tag:Name,Values=ec2-net-utils-vpc --query 'Addresses[].AllocationId' --output text)
aws ec2 release-address --region ${aws_region} --allocation-id $alloc_id

# Remove the key
aws ec2 delete-key-pair --key-name ec2-net-utils-key --region ${aws_region}

# Remove local files
rm variables.sh
rm ec2-net-utils-sshkey
rm ec2-net-utils-sshkey.pub
