#!/usr/bin/env python3
"""
Find merge requests in a specific state.

Copyright 2018 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import argparse
import getpass
import os

from launchpadlib.launchpad import Launchpad


def main(project):
    """Get versions and print"""
    cachedir = os.path.join('/home', getpass.getuser(), '.launchpadlib/cache/')
    launchpad = Launchpad.login_anonymously(
        'ubuntu-server merge proposal lookup', 'production',
        cachedir, version='devel'
    )

    if project.startswith('lp:'):
        branch = launchpad.branches.getByUrl(url=project)
    else:
        branch = launchpad.git_repositories.getByPath(
            path=project.replace('lp:', '')
        )

    if not branch:
        print('No branch named %s found' % project)
        return

    for merge in branch.landing_candidates:
        if merge.queue_status == 'Approved':
            print('./autoland.py --use-description-for-commit '
                    '--test-result PASSED --revision %s '
                    '--merge-proposal %s' %
                    (merge.reviewed_revid, merge))

if __name__ == '__main__':
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('project', help='project name')

    ARGS = PARSER.parse_args()
    main(ARGS.project)
