#!/usr/bin/env python3
"""Clean up all running EC2 instances, VPCs, and storage."""

# Copyright 2018 Canonical Ltd.
# Joshua Powers <josh.powers@canonical.com>

import argparse
import boto3
import datetime
import re


CI_DEFAULT_TAG = "uaclient-*"

# Our CI pycloudlib use reuses a single shared VPC across multiple
# CI jobs because VPCs counts are limited to 5 per region.
# cloud-init has one vpc and uaclient a 2nd shared VPC.
# If we have any instances running in this VPC, don't try to
# Remote security_groups, subnets, gateways
SHARED_VPC_TAG = "uaclent-integration"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-t", "--tag", dest="tag", action="store", default=CI_DEFAULT_TAG,
        help=("Tag used to filter cloud resources for deletion. "
              "Default: {}".format(CI_DEFAULT_TAG))
    )
    parser.add_argument(
        "-o", "--older-than", dest="older_than", action="store",
        help=("Tag used to filter cloud resources for deletion. "
              "Format: MM/DD/YY [HH:MM:SS].")
    )
    return parser.parse_args()


def get_tag_prefix(older_than):
    if not older_than:
       return ""
    print('Match only resources created before %s' % older_than)
    try:
        time = datetime.datetime.strptime(older_than, "%m/%d/%y %H:%M:%S")
        return time.strftime("uaclient-ci-%m%d-%H%M%S")
    except ValueError:
        time = datetime.datetime.strptime(older_than, "%m/%d/%y")
        return time.strftime("uaclient-ci-%m%d")


def delete_resource_by_tag(resource, tag, older_than_prefix):
    """Return whether the resource is older than older_than_prefix or has tag.

    If no Name tag present, assume stale and return True

    Returns: True if resource should be deleted
    """
    if isinstance(resource, dict):
        if "KeyName" in resource:
            tag_value = resource["KeyName"]
    else:
        for tag in resource.tags:
            if tag["Key"] != "Name":
                continue
            tag_value = tag["Value"]

    if older_than_prefix:
        if tag_value >= older_than_prefix:  # Resource is newer
            return False
    if '*' in tag:
        if not re.match(tag, tag_value):
            return False  # Value !match the cmdline provided -t <regex>
    elif tag_value != tag:
        return False  # Value not equal the cmdline provided -t <value>
    return True


def clean_ec2(tag_prefix, older_than=None):
    """Clean up all running EC2 instances, VPCs, and storage."""
    client = boto3.client('ec2')
    resource = boto3.resource('ec2')

    time_prefix = get_tag_prefix(older_than)
    print('# searching for vpcs matching tag {}'.format(
        "uaclient-integration")
    )
    tag_filter = [{'Name': 'tag:Name', 'Values': [tag_prefix]}]
    vpc_filter = [{'Name': 'tag:Name', 'Values': [SHARED_VPC_TAG]}]
    import pdb; pdb.set_trace()
    for vpc in list(resource.vpcs.filter(Filters=vpc_filter)):
        print('cleaning up vpc %s' % vpc.id)
        wait_instances = []
        skipped_instances = []
        skipped_resources = False
        for instance in vpc.instances.all():
            if not delete_resource_by_tag(instance, tag_prefix, time_prefix):
                skipped_instances.append(instance)
            print('terminating instance %s' % instance.id)
            instance.terminate()
            wait_instances.append(instance)

        for inst in skipped_instances:
            print(
                "left instance %s running; newer than %s" % (
                    inst.id, older_than
                )
            )
        for inst in wait_instances:
            print("waiting on %s" % inst.id)
            inst.wait_until_terminated()

        if skipped_instances:
            # Our CI pycloudlib use reuses a single shared VPC across multiple
            # CI jobs because VPCs counts are limited to 5 per region.
            # cloud-init has one vpc and uaclient a 2nd shared VPC.
            # If we have any instances running in this VPC, don't try to
            # Remote security_groups, subnets, gateways
            break
        for security_group in vpc.security_groups.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(
                security_group, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating security group %s' % security_group.id)
            security_group.delete()

        for subnet in vpc.subnets.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(subnet, SHARED_VPC_TAG, time_prefix):
                skipped_resources = True
                continue
            print('terminating subnet %s' % subnet.id)
            subnet.delete()

        for route_table in vpc.route_tables.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(
                route_table, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating route table %s' % route_table.id)
            route_table.delete()

        for internet_gateway in vpc.internet_gateways.filter(
            Filters=vpc_filter
        ):
            if not delete_resource_by_tag(
                internet_gateway, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating internet gateway %s' % internet_gateway.id)
            internet_gateway.detach_from_vpc(VpcId=vpc.id)
            internet_gateway.delete()
        if not skipped_resources:
            print('terminating vpc %s' % vpc.id)
            vpc.delete()

    print('# searching for ssh keys matching tag {}'.format(tag_prefix))
    key_name = {'Name': 'key-name', 'Values': [tag_prefix]}
    for key in client.describe_key_pairs(Filters=[key_name])['KeyPairs']:
        if not delete_resource_by_tag(key, tag_prefix, time_prefix):
            continue
        print('deleting ssh key %s' % key['KeyName'])
        client.delete_key_pair(KeyName=key['KeyName'])

    print('# searching for amis matching tag {}'.format(tag_prefix))
    for image in resource.images.filter(
        Owners=['self'], Filters=tag_filter
    ).all():
        if not delete_resource_by_tag(image, tag_prefix, time_prefix):
            continue
        print('removing custom ami %s' % image.id)
        client.deregister_image(ImageId=image.id)

    print('# searching for snapshots matching tag {}'.format(tag_prefix))
    for snapshot in resource.snapshots.filter(OwnerIds=['self']).all():
        if not delete_resource_by_tag(snapshot, tag_prefix, time_prefix):
            continue
        print('removing custom snapshot %s' % snapshot.id)
        client.delete_snapshot(SnapshotId=snapshot.id)


if __name__ == '__main__':
    args = parse_args()
    clean_ec2(args.tag, args.older_than)
