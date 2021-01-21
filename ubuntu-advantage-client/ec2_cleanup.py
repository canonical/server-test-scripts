#!/usr/bin/env python3
"""Clean up all running EC2 instances, VPCs, and storage."""

# Copyright 2018 Canonical Ltd.
# Joshua Powers <josh.powers@canonical.com>

import argparse
import boto3
import datetime
import re
import traceback


CI_DEFAULT_TAG = "uaclient-ci-*"

# Our CI pycloudlib use reuses a single shared VPC across multiple
# CI jobs because VPCs counts are limited to 5 per region.
# cloud-init has one vpc and uaclient a 2nd shared VPC.
# If we have any instances running in this VPC, don't try to
# remove security_groups, subnets, gateways
SHARED_VPC_TAG = "uaclient-integration"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-t", "--tag", dest="tag", action="store", default=CI_DEFAULT_TAG,
        help=("Tag used to filter cloud resources for deletion by tag. "
              "Default: {}".format(CI_DEFAULT_TAG))
    )
    parser.add_argument(
        "-b", "--before-date", dest="before_date", action="store",
        help=("Resources created before this date will be deleted."
              " Format: MM/DD/YY")
    )
    return parser.parse_args()


def get_time_prefix(tag, before_date):
    """Return time-based tag prefix used to limit deletion to stale resources

    :param tag: String of the general tag filter provided on the commandline.
    :param before_date: String of the format mm/dd/yyY

    :return: String to be used for further time-based filtering
    """
    if not before_date:
       return ""
    if not tag:
        tag = CI_DEFAULT_TAG
    tag = tag.replace("*", "")
    if tag[-1] != "-":
        tag += "-"
    print('Match only resources created before %s' % before_date)
    time = datetime.datetime.strptime(before_date, "%m/%d/%y")
    return time.strftime(tag + "%m%d")


def delete_resource_by_tag(resource, tag, time_prefix):
    """Return whether the resource is older than time_prefix or has tag.

    :param resource: Either a dict or boto3 instance related to a boto3
        resource. This can be an instance, security_group, subnet etc. SSH keys
        are processed as dictionaries which contain a KeyName key.
    :param tag: String provided of the generic filter tag provided on the
        commandline.
    :param time_prefix: Optional string providing a more specific time filter.
        When provided, limit deletion to only those resources older than
        time_prefix.

    If no Name tag present, assume stale and return True

    :return: True if resource should be deleted
    """
    tag_value = ""
    if isinstance(resource, dict):
        if "KeyName" in resource:
            tag_value = resource["KeyName"]
    elif resource.tags:
        for resource_tag in resource.tags:
            if resource_tag["Key"] != "Name":
                continue
            tag_value = resource_tag["Value"]
    if time_prefix:
        if tag_value >= time_prefix:  # Resource is newer
            return False
    if '*' in tag:
        if not re.match(tag, tag_value):
            return False  # Value !match the cmdline provided -t <regex>
    elif tag_value != tag:
        return False  # Value not equal the cmdline provided -t <value>
    return True


def clean_ec2(tag_prefix, before_date=None):
    """Clean up all running EC2 instances, VPCs, and storage."""
    client = boto3.client('ec2')
    resource = boto3.resource('ec2')

    time_prefix = get_time_prefix(tag_prefix, before_date)
    print('# searching for vpcs matching tag {}'.format(SHARED_VPC_TAG))
    tag_filter = [{'Name': 'tag:Name', 'Values': [tag_prefix]}]
    vpc_filter = [{'Name': 'tag:Name', 'Values': [SHARED_VPC_TAG]}]
    for vpc in list(resource.vpcs.filter(Filters=vpc_filter)):
        print('cleaning up vpc %s' % vpc.id)
        wait_instances = []
        skipped_instances = []
        skipped_resources = False
        for instance in vpc.instances.all():
            if not delete_resource_by_tag(instance, tag_prefix, time_prefix):
                skipped_instances.append(instance)
                continue
            print('terminating instance %s' % instance.id)
            try:
                instance.terminate()
                wait_instances.append(instance)
            except Exception:
                print("Failure on terminating instance: {}".format(
                    instance.id))
                print("Exception: \n{}".format(traceback.print_exc()))


        for inst in skipped_instances:
            print(
                "left instance %s running; newer than %s" % (
                    inst.id, before_date
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
            # remove security_groups, subnets, gateways
            break
        for security_group in vpc.security_groups.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(
                security_group, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating security group %s' % security_group.id)
            try:
                security_group.delete()
            except Exception:
                print("Failure on terminating security group: {}".format(
                    security_group.id))
                print("Exception: \n{}".format(traceback.print_exc()))

        for subnet in vpc.subnets.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(subnet, SHARED_VPC_TAG, time_prefix):
                skipped_resources = True
                continue
            print('terminating subnet %s' % subnet.id)
            try:
                subnet.delete()
            except Exception:
                print("Failure on terminating subnet: {}".format(
                    subnet.id))
                print("Exception: \n{}".format(traceback.print_exc()))

        for route_table in vpc.route_tables.filter(Filters=vpc_filter):
            if not delete_resource_by_tag(
                route_table, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating route table %s' % route_table.id)
            try:
                route_table.delete()
            except Exception:
                print("Failure on terminating route table: {}".format(
                    route_table.id))
                print("Exception: \n{}".format(traceback.print_exc()))

        for internet_gateway in vpc.internet_gateways.filter(
            Filters=vpc_filter
        ):
            if not delete_resource_by_tag(
                internet_gateway, SHARED_VPC_TAG, time_prefix
            ):
                skipped_resources = True
                continue
            print('terminating internet gateway %s' % internet_gateway.id)
            try:
                internet_gateway.detach_from_vpc(VpcId=vpc.id)
                internet_gateway.delete()
            except Exception:
                print("Failure on terminating internet gateway: {}".format(
                    internet_gateway.id))
                print("Exception: \n{}".format(traceback.print_exc()))

        if not skipped_resources:
            print('terminating vpc %s' % vpc.id)
            try:
                vpc.delete()
            except Exception:
                print("Failure on terminating vpc: {}".format(
                    vpc.id))
                print("Exception: \n{}".format(traceback.print_exc()))


    print('# searching for ssh keys matching tag {}'.format(tag_prefix))
    key_name = {'Name': 'key-name', 'Values': [tag_prefix]}
    for key in client.describe_key_pairs(Filters=[key_name])['KeyPairs']:
        if not delete_resource_by_tag(key, tag_prefix, time_prefix):
            continue
        print('deleting ssh key %s' % key['KeyName'])
        try:
            client.delete_key_pair(KeyName=key['KeyName'])
        except Exception:
            print("Failure on terminating ssh key: {}".format(
                key['KeyName']))
            print("Exception: \n{}".format(traceback.print_exc()))


    print('# searching for amis matching tag {}'.format(tag_prefix))
    for image in resource.images.filter(
        Owners=['self'], Filters=tag_filter
    ).all():
        if not delete_resource_by_tag(image, tag_prefix, time_prefix):
            continue
        print('removing custom ami %s' % image.id)
        try:
            client.deregister_image(ImageId=image.id)
        except Exception:
            print("Failure on removing custom ami: {}".format(
                image.id))
            print("Exception: \n{}".format(traceback.print_exc()))

    print('# searching for snapshots matching tag {}'.format(tag_prefix))
    for snapshot in resource.snapshots.filter(OwnerIds=['self']).all():
        if not delete_resource_by_tag(snapshot, tag_prefix, time_prefix):
            continue
        print('removing custom snapshot %s' % snapshot.id)
        try:
            client.delete_snapshot(SnapshotId=snapshot.id)
        except:
            print("Failure on removing custom snapshot: {}".format(
                snapshot.id))
            print("Exception: \n{}".format(traceback.print_exc()))


if __name__ == '__main__':
    args = parse_args()
    clean_ec2(args.tag, args.before_date)
