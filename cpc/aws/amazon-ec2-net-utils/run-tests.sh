#!/bin/bash


if ! command -v sshuttle &> /dev/null; then
    echo "Please install sshuttle first"
    echo "    sudo apt install sshuttle"
    exit 1
fi

if [[ -z $1 ]]; then
   echo "Please choose an AWS region"
   exit 1
else
	if [[ -z $2 ]]; then
		echo "Please choose an instance type"
		exit 1
	else
		if [[ -z $3 ]]; then
			echo "Please choose an Ubuntu release"
			exit 1
		fi
	fi
fi

# TODO check that aws creds are working

aws_region=$1
instance_type=$2
release=$3

echo "Creating resources"
./pre-create-vpc-and-subnets.sh $aws_region $instance_type $release

echo "Running tests"
./test-amazon-ec2-net-utils.sh
test_result=$?
if [ $test_result -eq 1 ]; then
        echo "The amazon-ec2-net-utils package installation failed. Breaking here!"
        exit 1
fi

echo "Deleting resources"
./delete-vpc-and-subnets.sh $aws_region

if [ $test_result -eq 0 ]; then
        echo "Test succeeded!"
        exit 0
else
        echo "Test failed!"
        exit 2
fi
