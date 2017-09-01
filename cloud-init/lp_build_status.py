#!/usr/bin/env python3
"""Report daily Launchpad build status for cloud-init.

Copyright 2017 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import json
from urllib.request import urlopen

BUILD_URL = ('https://api.launchpad.net/devel/~cloud-init-dev/'
             '+recipe/cloud-init-daily-devel/builds')
RESULTS_FILENAME = 'results.xml'


def download_build_results():
    """Download Launchpad build results in JSON."""
    with urlopen(BUILD_URL) as url:
        data = json.loads(url.read().decode())

    return data['entries']


def print_results(distro, build_pass, build_error=''):
    """Print results to junit like xml file."""
    header = '<testsuite tests="1">'
    footer = "</testsuite>"

    if build_pass:
        result = '\t<testcase classname="%s" name="Build"/>\n' % distro
    else:
        result = ('\t<testcase classname="%s" name="Build">\n'
                  '\t\t<failure type="BuildFailure">%s</failure>\n'
                  '\t</testcase>\n' % (distro, build_error))

    with open(RESULTS_FILENAME, 'w') as out:
        out.write('%s\n\t%s\n%s\n' % (header, result, footer))


def main():
    """Create result.xml from latest build result."""
    builds = download_build_results()

    # Only build latest release, so report first entry
    latest_build = builds[0]
    distro = latest_build['distro_series_link'].split('/')[-1]
    build_pass = True if latest_build['buildstate'] else False

    print_results(distro, build_pass, latest_build['buildstate'])

if __name__ == '__main__':
    main()
