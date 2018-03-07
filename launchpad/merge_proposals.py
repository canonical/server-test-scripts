#!/usr/bin/env python3
"""
Find merge requests in a specific state.

Copyright 2018 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import argparse

from launchpadlib.launchpad import Launchpad


def main(project, state):
    """Get versions and print"""
    launchpad = Launchpad.login_with(
        'ubuntu-server merge proposal lookup', 'production',
        version='devel',
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
        if merge.queue_status in state:
            print('%s %s' % (merge, merge.reviewed_revid))


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('project', help='project name')
    PARSER.add_argument('--state', default='Approved',
                        help='Work in progress, Needs review, Approved, '\
                             'Rejected, or Merged')

    ARGS = PARSER.parse_args()
    main(ARGS.project, ARGS.state)
