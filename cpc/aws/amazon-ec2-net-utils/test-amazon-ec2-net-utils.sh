#!/bin/bash

set -x

# Get variables from config.sh
source variables.sh

ssh_flags=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null "
ssh_key="./ec2-net-utils-sshkey"

wait_for_ssh() {
    # $1 is ipaddr
    local max_ssh_attempts=10
    local ssh_attempt_sleep_time=10
    local ipaddr=$1

    # Start with a sleep so that it waits a bit in case of a reboot
    sleep $ssh_attempt_sleep_time

    # Loop until SSH is successful or max_attempts is reached
    for ((i = 1; i <= $max_ssh_attempts; i++)); do
        ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} exit
        if [ $? -eq 0 ]; then
            echo "SSH connection successful."
            break
        else
            echo "Attempt $i: SSH connection failed. Retrying in $ssh_attempt_sleep_time seconds..."
            sleep $ssh_attempt_sleep_time
        fi
    done

    if [ $i -gt $max_ssh_attempts ]; then
        echo "Max SSH connection attempts reached. Exiting."
    fi
}

# Create an instance on public subnet
router_instance_id=$(aws ec2 run-instances \
    --region ${aws_region} \
    --image-id ${aws_ami} \
    --count 1 \
    --instance-type ${aws_instance_type} \
    --key-name ec2-net-utils-key \
    --security-group-ids ${aws_security_group} \
    --associate-public-ip-address \
    --subnet-id ${aws_public_subnet} \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${aws_routerinstance_name}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

# Create new ENI on the private subnet
router_eni_id=$(aws ec2 create-network-interface \
  --region $aws_region \
  --subnet-id ${aws_subnet} \
  --description "amazon-ec2-net-utils-router" \
  --groups $aws_security_group \
  --query 'NetworkInterface.NetworkInterfaceId' \
  --output text)

aws ec2 wait instance-running --region $aws_region --instance-ids $router_instance_id
router_attachment_id=$(aws ec2 attach-network-interface \
  --region $aws_region \
  --network-interface-id $router_eni_id \
  --instance-id $router_instance_id \
  --device-index 1 \
  --query 'AttachmentId' \
  --output text)

router_ipaddr=$(aws ec2 describe-instances --instance-ids $router_instance_id --region $aws_region \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

wait_for_ssh $router_ipaddr

# Get the VPC CIDR
vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids ${aws_vpc} --region $aws_region --query 'Vpcs[0].CidrBlockAssociationSet[0].CidrBlock' --output text)

# Open the sshuttle
nohup sshuttle -e "ssh $ssh_flags -i $ssh_key" -r ubuntu@$router_ipaddr $vpc_cidr &
sshuttle_pid=$!

# Create the instance
instance_id=$(aws ec2 run-instances \
    --region ${aws_region} \
    --image-id ${aws_ami} \
    --count 1 \
    --instance-type ${aws_instance_type} \
    --key-name ec2-net-utils-key \
    --security-group-ids ${aws_security_group} \
    --subnet-id ${aws_subnet} \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${aws_instance_name}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

# Create new ENI
eni_id=$(aws ec2 create-network-interface \
  --region $aws_region \
  --subnet-id ${aws_subnet} \
  --description "amazon-ec2-net-utils-test" \
  --groups $aws_security_group \
  --query 'NetworkInterface.NetworkInterfaceId' \
  --output text)

aws ec2 wait instance-running --region $aws_region --instance-ids $instance_id
instance_attachment_id=$(aws ec2 attach-network-interface \
  --region $aws_region \
  --network-interface-id $eni_id \
  --instance-id $instance_id \
  --device-index 1 \
  --query AttachmentId \
  --output text)

ipaddr=$(aws ec2 describe-instances --instance-ids $instance_id --region $aws_region \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

wait_for_ssh $ipaddr

# Enable proposed
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
    'echo "deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs)-proposed restricted main multiverse universe" | sudo tee /etc/apt/sources.list.d/ubuntu-$(lsb_release -cs)-proposed.list'

# install amazon-ec2-net-utils
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
    'sudo apt-get update -y && sudo apt-get install -y amazon-ec2-net-utils -t $(lsb_release -cs)-proposed'

## Temporarily install from local build
#ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
#       'wget https://people.canonical.com/~fabiomirmar/amazon-ec2-net-utils_2.4.0-1~1_all.deb'
#ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
#       'sudo dpkg -i amazon-ec2-net-utils_2.4.0-1~1_all.deb'

if [ $? -ne 0 ]; then
        echo "Something failed. Better break here!"
        exit 1
fi

# Check version
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
    dpkg -l amazon-ec2-net-utils | grep amazon-ec2-net-utils | awk '{print $3}'

# Remove netplan yaml so that amazon-ec2-net-utils takes control upon reboot
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
    'sudo rm /etc/netplan/50-cloud-init.yaml'

# Reboot the instance since we dont have a postinst
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
	'sudo reboot'

wait_for_ssh $ipaddr

# Now at this point, we should have 2 NICs with 2 different IP addresses.
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} 'sudo ip a'
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} 'sudo ip rule show'
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} 'sudo ip route show'

# Display the table for each interface
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
	'for interface in `basename -a /sys/class/net/en*`; do echo "$interface: $(ip route show table $(cat /run/systemd/network/70-$interface.network.d/ec2net_policy_*.conf | grep Table | cut -d \= -f 2))"; done'

# Ping www.google.com from all interfaces
ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
	'for interface in `basename -a /sys/class/net/en*`; do ping -I $interface -c 1 -w 1 www.google.com; done'
ping_result=$?

version=$(ssh $ssh_flags -i $ssh_key ubuntu@${ipaddr} \
    dpkg -l amazon-ec2-net-utils | grep amazon-ec2-net-utils | awk '{print $3}')

echo "amazon-ec2-net-utils $version tested"

# Kill sshuttle
kill $sshuttle_pid

#Terminate instances and ENIs
aws ec2 detach-network-interface --region $aws_region --attachment-id $router_attachment_id
aws ec2 detach-network-interface --region $aws_region --attachment-id $instance_attachment_id
aws ec2 terminate-instances --region $aws_region --instance-ids $router_instance_id $instance_id
aws ec2 wait instance-terminated --region $aws_region --instance-ids $router_instance_id $instance_id
aws ec2 wait network-interface-available --region $aws_region --network-interface-ids $router_eni_id
aws ec2 delete-network-interface --region $aws_region --network-interface-id $router_eni_id
aws ec2 wait network-interface-available --region $aws_region --network-interface-ids $eni_id
aws ec2 delete-network-interface --region $aws_region --network-interface-id $eni_id

if [ $ping_result -eq 0 ]; then
	echo "Test succeeded!"
	exit 0
else
	echo "Test failed!"
	exit 2
fi
