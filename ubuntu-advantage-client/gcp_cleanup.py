#!/usr/bin/env python3
"""Clean up all running GCP instances."""

# Copyright 2021 Canonical Ltd.
# Lucas Moura <lucas.moura@canonical.com>

import argparse
import datetime
import pycloudlib


CI_DEFAULT_TAG = "uaclient"


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-t", "--tag", dest="tag", action="store",
        default=CI_DEFAULT_TAG,
        help=(
            "Tag to determine which instances will be deleted."
            "If the tag is present in the instance name, it will "
            "be marked for deletion. "
            "Default: {}".format(CI_DEFAULT_TAG))
    )
    parser.add_argument(
        "-b", "--before-date", dest="before_date", action="store",
        help=("Resources created before this date will be deleted."
              " Format: MM/DD/YY")
    )
    parser.add_argument(
        "--credentials-path", dest="credentials_path",
        help="""
            Path to json file representing the GCP credentials. That file
            must a be a json dict containing all the necessary credentials
            to manage GCP resources."""
        )
    parser.add_argument(
        "--project-id", dest="project_id",
        help="Name of the project id this script will operate on"
    )
    parser.add_argument(
        "--region", dest="region",
        help="Name of the region this script will operate on"
    )
    parser.add_argument(
        "--zone", dest="zone",
        help="Name of the zone this script will operate on"
    )

    return parser


def clean_gcp(credentials_path, project_id, tag, before_date, region, zone):
    gce = pycloudlib.GCE(
        tag='cleanup',
        credentials_path=credentials_path,
        project=project_id,
        region=region,
        zone=zone
    )

    all_instances = gce.compute.instances().list(
        project=gce.project,
        zone=gce.zone
    ).execute()

    for instance in all_instances.get('items', []):
        created_at = datetime.datetime.strptime(
            instance["creationTimestamp"].split("T")[0], "%Y-%M-%d"
        )

        if tag in instance['name'] and created_at < before_date:
            print("Deleting instance {} ...".format(
                instance['name']))
            instance = gce.get_instance(
                instance_id=instance['name']
            )

            instance.delete()


if __name__ == '__main__':
    parser = get_parser()
    args = parser.parse_args()

    if args.before_date:
        before_date = datetime.datetime.strptime(
                    args.before_date, "%M/%d/%Y"
        )
    else:
        before_date = datetime.datetime.today() - datetime.timedelta(days=1)

    clean_gcp(
        credentials_path=args.credentials_path,
        project_id=args.project_id,
        tag=args.tag,
        before_date=before_date,
        region=args.region,
        zone=args.zone
    )
