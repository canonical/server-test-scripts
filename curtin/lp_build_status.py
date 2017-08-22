#!/usr/bin/env python3
"""Report daily Launchpad build status for curtin.

Copyright 2017 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import json
from urllib.request import urlopen

BUILD_URL = ('https://api.launchpad.net/devel/~curtin-dev/'
             '+recipe/curtin-trunk/builds')
RESULTS_FILENAME = 'results.xml'


def download_build_results():
    """Download Launchpad build results in JSON."""
    with urlopen(BUILD_URL) as url:
        data = json.loads(url.read().decode())

    return data['entries']


def print_results(results):
    """Print results to junit like xml file."""
    header = '<testsuite tests="%s">' % len(results)
    footer = '</testsuite>'
    content = ''

    for distro, result in results.items():
        if result['pass']:
            content += '\t<testcase classname="%s" name="Build"/>\n' % distro
        else:
            content += ('\t<testcase classname="%s" name="Build">'
                      '<failure type="BuildFailure">%s</failure>'
                      '</testcase>\n' % (distro, result['buildstate']))

    with open(RESULTS_FILENAME, 'w') as out:
        out.write('%s\n%s%s\n' % (header, content, footer))


def main():
    """Create result.xml from latest build result."""
    builds = download_build_results()

    results = {}
    for build in builds:
        distro = build['distro_series_link'].split('/')[-1]
        if distro in results:
            continue

        results[distro] = {}
        results[distro]['pass'] = True if build['buildstate'] else False
        results[distro]['buildstate'] = build['buildstate']

    print_results(results)


if __name__ == '__main__':
    main()
