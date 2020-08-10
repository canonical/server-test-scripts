#!/usr/bin/env python3
"""Clean up all running Azure resources and resource groups."""

# Copyright 2020 Canonical Ltd.
# Lucas Moura <lucas.moura@canonical.com>

from pycloudlib.azure.util import get_client
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.resource import ResourceManagementClient

import argparse


CI_DEFAULT_TAG = "uaclient"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-t", "--tag", dest="tag", action="store", default=CI_DEFAULT_TAG,
        help=("Tag used to filter cloud resources for deletion. "
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
    return parser.parse_args()


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
                    print('# deleting resource group: {}'.format(
                        resource_group_name))
                    result = resource_client.resource_groups.delete(
                        resource_group_name=resource_group_name
                    )
                    result.wait()
                    break


if __name__ == '__main__':
    args = parse_args()
    clean_azure(
        tag=args.tag,
        client_id=args.client_id,
        client_secret=args.client_secret,
        tenant_id=args.tenant_id,
        subscription_id=args.subscription_id
    )
