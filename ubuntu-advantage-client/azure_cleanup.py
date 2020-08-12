#!/usr/bin/env python3
"""Clean up all running Azure resources and resource groups."""

# Copyright 2020 Canonical Ltd.
# Lucas Moura <lucas.moura@canonical.com>
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
        "-t", "--tag", dest="tag", action="store", default=CI_DEFAULT_TAG,
        help=(
            "Tag used as a prefix to search for resources to be deleted."
            "Default: {}".format(CI_DEFAULT_TAG))
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


def clean_azure(tag, client_id, client_secret, tenant_id, subscription_id):
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

    print('# searching for resource groups matching tag {}'.format(tag))
    for resource_group in resource_client.resource_groups.list():
        tags = resource_group.tags

        if tags:
            for tag_value in tags.values():
                if tag_value.startswith(tag):
                    resource_group_name = resource_group.name
                    print('# deleted resource group: {} with tag {}'.format(
                        resource_group_name, tag))
                    result = resource_client.resource_groups.delete(
                        resource_group_name=resource_group_name
                    )
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
            tag=args.tag,
            **config_dict
        )
    else:
        clean_azure(
            tag=args.tag,
            client_id=args.client_id,
            client_secret=args.client_secret,
            tenant_id=args.tenant_id,
            subscription_id=args.subscription_id
        )
