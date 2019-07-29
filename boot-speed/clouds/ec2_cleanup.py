#!/usr/bin/env python3
"""Clean up long-running (= stale) bootspeed-* EC2 instances.

Copyright 2018-2019 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
Paride Legovini <paride.legovini@canonical.com>
"""
import boto3
import datetime as dt
import os
import re


def clean_ec2():
    """Clean up all running EC2 instances tagged 'bootspeed-*'."""

    # Maximum instance age (in minutes)
    max_inst_age = os.environ.get('MAX_EC2_INST_AGE', 120)

    # Seconds since epoch; will be compared with the timestamp we put
    # in the instance tag to determine if instances are stale.
    now = int(dt.datetime.utcnow().timestamp())

    resource = boto3.resource('ec2')
    inst_tag = [{'Name': 'tag:Name', 'Values': ['bootspeed-*']}]
    stale_instances = []
    for vpc in list(resource.vpcs.all()):
        print('# cleaning up vpc %s\n' % vpc.id)
        for instance in vpc.instances.filter(Filters=inst_tag):
            for tag in instance.tags:
                if tag['Key'] == 'Name' and re.match(
                        "^bootspeed-[0-9]+$", tag['Value']):
                    print('Found bootspeed instance %s' % instance.id)
                    timestamp = int(tag['Value'].split("-")[1])
                    tdelta = now - timestamp
                    print('Instance started %s seconds ago' % tdelta)
                    if tdelta > max_inst_age*60:
                        print("Terminating stale instance.")
                        stale_instances.append(instance)
                        instance.terminate()
                    print()

    for instance in stale_instances:
        print("Waiting for %s to be terminated." % instance.id)
        instance.wait_until_terminated()

    print("Done")


if __name__ == '__main__':
    clean_ec2()
