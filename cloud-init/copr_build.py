#!/usr/bin/env python3
"""Create cloud-init srpm build via COPR.

https://copr.fedorainfracloud.org/coprs/g/cloud-init/

Copyright 2017 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import argparse
import datetime
import os
import sys
import time

import copr

ID_CLOUD_INIT = 13995
ID_CLOUD_INIT_DEV = 14567
TEST_CHROOTS = ['epel-6-x86_64', 'epel-7-x86_64']
URL_COPR = "https://copr.fedorainfracloud.org/coprs/g/cloud-init"


def check_test_chroot(tasks):
    """Checks the status of specific chroots for testing."""
    print('\nChecking stauts of test chroot(s):\n')
    for chroot in TEST_CHROOTS:
        print('%24s: %s' % (chroot, tasks[chroot]))
        if tasks[chroot] != 'succeeded':
            print('Build failed!')
            sys.exit(1)


def check_build_status(build, tasks):
    """Check status of builds in each chroot."""
    tasks_watched = set(tasks.keys())
    tasks_done = set()

    print('\nChecking stauts of build(s):\n')
    while tasks_watched != tasks_done:
        for task in build.get_build_tasks():
            name = task.chroot_name
            state_cur = task.state
            state_previous = tasks[name]

            if name in tasks_done:
                continue

            if state_cur in ["skipped", "failed", "succeeded"]:
                tasks_done.add(name)

            if state_previous != state_cur:
                tasks[name] = state_cur
                print("%24s: %s --> %s" % (name, state_previous, state_cur))

        time.sleep(10)


def get_build_tasks(build):
    """Get build tasks."""
    tasks = {}
    for chroot in build.get_build_tasks():
        tasks[chroot.chroot_name] = 'importing'

    print('\nBuilding in the following chroot(s):\n')
    for key in sorted(tasks):
        print('     * %s' % key)

    return tasks


def launch_build(project, srpm):
    """Launch a build from given srpm."""
    build = project.create_build_from_file(srpm, enable_net=False)

    print('Started COPR build on %s (ID: %s)' % (project.name, build.id))
    print('%s/%s/build/%s' % (URL_COPR, project.name, build.id))

    return build


def main(srpm, copr_conf=None, dev=None):
    """Query COPR info."""
    if not os.path.isfile(srpm):
        print("Error: The given SRPM is not a file:\n%s" % srpm)
        sys.exit(1)

    project_id = ID_CLOUD_INIT_DEV if dev else ID_CLOUD_INIT
    client = copr.create_client2_from_file_config(copr_conf)
    project = client.projects.get_one(project_id)

    print(datetime.datetime.now())
    build = launch_build(project, srpm)
    tasks = get_build_tasks(build)
    check_build_status(build, tasks)
    check_test_chroot(tasks)
    print()
    print(datetime.datetime.now())


if __name__ == '__main__':
    ARGPARSER = argparse.ArgumentParser(description='cloud-init copr script')
    ARGPARSER.add_argument('-c', '--config', dest='copr_conf', action='store',
                           help='copr config file location')
    ARGPARSER.add_argument('-d', '--dev', dest='dev', action='store_true',
                           help='use cloud-init-dev instead of cloud-init')
    ARGPARSER.add_argument('-s', '--srpm', dest='srpm', action='store',
                           required=True, help='srpm file')
    ARGS = ARGPARSER.parse_args()

    main(ARGS.srpm, ARGS.copr_conf, ARGS.dev)
