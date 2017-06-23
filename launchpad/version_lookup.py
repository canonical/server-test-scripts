#!/usr/bin/env python3
"""
Look up what version a package is in any release, pocket, or status.

Copyright 2016 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import argparse
import getpass
import os

from launchpadlib.launchpad import Launchpad


def connect_launchpad():
    """Using the launchpad module connect to launchpad anonymously"""
    cachedir = os.path.join('/home', getpass.getuser(), '.launchpadlib/cache/')
    return Launchpad.login_anonymously('proposed_query', 'production',
                                       cachedir, version='devel')


def main(src_name, release=None, pocket=None, status=None):
    """Get versions and print"""
    launchpad = connect_launchpad()
    ubuntu = launchpad.distributions['Ubuntu']
    archive = ubuntu.main_archive

    args = dict(
        exact_match=True,
        order_by_date=True,
        source_name=src_name,
    )

    if release:
        args['distro_series'] = ubuntu.getSeries(name_or_version=release)

    if pocket:
        args['pocket'] = pocket

    if status:
        args['status'] = status

    srcpkgs = archive.getPublishedSources(**args)

    for src in srcpkgs:
        print('{},{},{},{},{}'.format(src_name, src.distro_series.name,
                                      src.pocket, src.status,
                                      src.source_package_version))


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('src_name', help='source package name')
    PARSER.add_argument('-r', '--release', help='a valid release name \
                        like xenial')
    PARSER.add_argument('-p', '--pocket', help='Release, Security, \
                        Updates, Proposed, or Backports')
    PARSER.add_argument('-s', '--status', help='Pending, Published, \
                        Superseded, Deleted, or Obsolete')

    ARGS = PARSER.parse_args()
    main(ARGS.src_name, ARGS.release, ARGS.pocket, ARGS.status)
