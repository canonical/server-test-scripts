#!/usr/bin/env python3
"""Clean up all stale LXC resources"""

# Copyright 2020 Canonical Ltd.
import argparse
import datetime
import json
from subprocess import run, PIPE

DEFAULT_NAME_PREFIX = "ubuntu-behave-test"


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-b", "--before-date", dest="before_date", action="store",
        help=("Resources created before this date will be deleted."
              " Format: MM/DD/YY")
    )
    parser.add_argument(
        "-p", "--prefix", dest="prefix", action="store", required=False,
        default=DEFAULT_NAME_PREFIX,
        help=("Delete only instances with the provided name prefix."
              " Default: {}".format(DEFAULT_NAME_PREFIX))
    )
    return parser


if __name__ == '__main__':
    parser = get_parser()
    args = parser.parse_args()
    if args.before_date:
        before_date = datetime.datetime.strptime(
                    args.before_date, "%M/%d/%Y"
        )
    else:
        before_date = datetime.datetime.today() - datetime.timedelta(days=1)
    result = run(["lxc", "ls", "--format=json"], stdout=PIPE)
    if result.stdout:
        for instance in json.loads(result.stdout):
            if instance["name"].startswith(args.prefix):
                created_at = datetime.datetime.strptime(
                    instance["created_at"].split("T")[0], "%Y-%M-%d"
                )
                if created_at < before_date:
                    print("Deleting: {}".format(instance["name"]))
                    try:
                        run(
                            ["lxc", "delete", "--force", instance["name"]],
                            timeout=20
                        )
                    except TimeoutExpired:
                        print(
                            "Warning: could not delete lxc {} due to"
                            " timeout".format(instance["name"])
                        )
