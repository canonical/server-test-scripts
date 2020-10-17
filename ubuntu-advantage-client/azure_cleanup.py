#!/usr/bin/env python3
"""Clean up all running Azure resources and resource groups."""

# Copyright 2020 Canonical Ltd.
# Lucas Moura <lucas.moura@canonical.com>
from contextlib import contextmanager
import os
import json
import sys

from pycloudlib.azure.util import get_client
from azure.mgmt.resource import ResourceManagementClient

import argparse


CI_DEFAULT_TAG = "uaclient"


def get_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-pt", "--prefix-tag", dest="prefix_tag", action="store",
        default=CI_DEFAULT_TAG,
        help=(
            "Tag used as a prefix to search for resources to be deleted."
            "Default: {}".format(CI_DEFAULT_TAG))
    )
    parser.add_argument(
        "-st", "--suffix-tag", dest="suffix_tag", action="store",
        help=("Tag used as a suffix to search for resources to be deleted.")
    )
    parser.add_argument(
        "--client-id", dest="client_id",
        help="Client id used to access azure api"
    )
    parser.add_argument(
        "--client-secret", dest="client_secret",
        help="Client secret used to access azure api"
    )
    parser.add_argument(
        "--tenant-id", dest="tenant_id",
        help="Tenant id used to access azure api"
    )
    parser.add_argument(
        "--subscription-id", dest="subscription_id",
        help="Subscription id used to access azure api"
    )
    parser.add_argument(
        "--credentials-file", dest="credentials_file",
        help="""
            Json file representing the Azure credentials. That file must a be
            a json dict containing all the necessary credentials to manage
            Azure resources. To successfuly be used in this script,
            the json file must have the following keys:  client_id,
            client_secret, tenant_id, subscription_id.
            """
        )

    return parser


@contextmanager
def emit_dots_on_travis():
    """
    A context manager that emits a dot every 10 seconds if running on Travis.
    Travis will kill jobs that don't emit output for a certain amount of time.
    This context manager spins up a background process which will emit a dot to
    stdout every 10 seconds to avoid being killed.
    It should be wrapped selectively around operations that are known to take a
    long time.

    PS: This function was originally created for cloud-init integration tests.
    It was added at PR #347.
    """
    if os.environ.get('TRAVIS') != "true":
        # If we aren't on Travis, don't do anything.
        yield
        return

    def emit_dots():
        while True:
            print(".")
            time.sleep(10)

    dot_process = multiprocessing.Process(target=emit_dots)
    dot_process.start()
    try:
        yield
    finally:
        dot_process.terminate()


def check_tag(tag, prefix_tag, suffix_tag):
    """Check for a match in the tag using both prefix_tag and suffix_tag"""
    prefix_check = tag.startswith(prefix_tag)

    if suffix_tag:
        prefix_check &= tag.endswith(suffix_tag)

    return prefix_check


def clean_azure(prefix_tag, suffix_tag, client_id, client_secret, tenant_id, subscription_id):
    """Clean up all running Azure resources and resource groups"""
    config_dict = {
        "clientId": client_id,
        "clientSecret": client_secret,
        "tenantId": tenant_id,
        "subscriptionId": subscription_id
    }

    resource_client = get_client(
        ResourceManagementClient, config_dict
    )

    print('# searching for resource groups matching tag {}'.format(prefix_tag))
    for resource_group in resource_client.resource_groups.list():
        tags = resource_group.tags

        if tags:
            for tag_value in tags.values():
                if check_tag(tag_value, prefix_tag, suffix_tag):
                    resource_group_name = resource_group.name
                    print('# deleted resource group: {} with tag {}'.format(
                        resource_group_name, tag_value))
                    result = resource_client.resource_groups.delete(
                        resource_group_name=resource_group_name
                    )

                    with emit_dots_on_travis():
                        result.wait()

                    break


def load_azure_config(credentials_file):
    with open(credentials_file, 'r') as f:
        all_credentials = json.load(f)

        return {
            "client_id": all_credentials["clientId"],
            "client_secret": all_credentials["clientSecret"],
            "tenant_id": all_credentials["tenantId"],
            "subscription_id": all_credentials["subscriptionId"]
        }


if __name__ == '__main__':
    parser = get_parser()
    args = parser.parse_args()
    individ_args = all(
        [
            args.client_id, args.client_secret,
            args.tenant_id, args.subscription_id
        ]
    )
    if not any([args.credentials_file, individ_args]):
        print("Either --credentials-file or tenant and client args required")
        parser.print_help()
        sys.exit(1)

    if args.credentials_file:
        if not os.path.exists(args.credentials_file):
            raise Exception("File {} could not be found".format(
                args.credentials_file))

        config_dict = load_azure_config(
            args.credentials_file
        )
        clean_azure(
            prefix_tag=args.prefix_tag,
            suffix_tag=args.suffix_tag,
            **config_dict
        )
    else:
        clean_azure(
            prefix_tag=args.prefix_tag,
            suffix_tag=args.suffix_tag,
            client_id=args.client_id,
            client_secret=args.client_secret,
            tenant_id=args.tenant_id,
            subscription_id=args.subscription_id
        )
