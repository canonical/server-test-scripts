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

from botocore.exceptions import WaiterError


def clean_ec2():
    """Clean up all running EC2 instances tagged 'bootspeed-*'."""
    # Maximum instance age (in minutes)
    max_inst_age = int(os.environ.get('MAX_EC2_INST_AGE', 120))

    # Seconds since epoch; will be compared with the timestamp we put
    # in the instance tag to determine if instances are stale.
    now = int(dt.datetime.utcnow().timestamp())

    print("Max allowed age of instances: %d minutes" % max_inst_age)

    resource = boto3.resource('ec2')
    inst_tag = [{'Name': 'tag:Name', 'Values': ['bootspeed-*']}]
    stale_instances = []
    for vpc in list(resource.vpcs.all()):
        print('Cleaning up vpc %s' % vpc.id)
        for instance in vpc.instances.filter(Filters=inst_tag):
            for tag in instance.tags:
                if tag['Key'] == 'Name' and re.match(
                        "^bootspeed-[0-9]+$", tag['Value']):
                    print('- Found bootspeed instance %s' % instance.id)
                    timestamp = int(tag['Value'].split("-")[1])
                    tdelta = now - timestamp
                    print('  Instance started %s seconds ago' % tdelta)
                    if tdelta > max_inst_age*60:
                        print("  Stale instance, terminating.")
                        stale_instances.append(instance)
                        instance.terminate()
                    break

    for instance in stale_instances:
        print("Waiting for %s to be terminated" % instance.id)

        # On metal instances wait_until_terminated() sometimes fails, likely
        # because of the long reaction times of such instances. Versions
        # botocore/boto3 newer than the one in Bionic may behave better
        # from this point of view. Here we work around the issue by retrying
        # wait_until_terminated() in case of WaiterError.
        #
        # This is not nice, but the critical thing here is to be sure not to
        # leave lingering instances.
        try:
            instance.wait_until_terminated()
        except WaiterError:
            print("- WaiterError, trying again.")
            instance.wait_until_terminated()

    print("Done")


if __name__ == '__main__':
    clean_ec2()
