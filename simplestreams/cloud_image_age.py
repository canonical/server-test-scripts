#!/usr/bin/env python3
"""Report oldest daily image age for a release on all clouds.

Copyright 2017 Canonical Ltd.
Joshua Powers <josh.powers@canonical.com>
"""
import argparse
from datetime import datetime
import json
import shlex
import subprocess
import sys


from distro_info import UbuntuDistroInfo

AGE_LIMIT = 4
RESULTS_FILENAME = 'results.xml'
SUPPORTED_CLOUDS = ['azure', 'cloud', 'ec2', 'gce', 'maas', 'maas3']
SUPPORTED_RELEASES = UbuntuDistroInfo().supported()


def print_results(results):
    """Print results to junit like xml file."""
    header = '<testsuite tests="%s">' % len(results)
    footer = '</testsuite>'
    content = ''

    for cloud, age in results.items():
        if age == 'None':
            content += ('\t<testcase classname="%s" name="Build">\n'
                        '\t\t<skipped />\n'
                        '\t</testcase>\n' % cloud)
        elif age < AGE_LIMIT:
            content += '\t<testcase classname="%s" name="Build"/>\n' % cloud
        else:
            content += ('\t<testcase classname="%s" name="Build">\n'
                        '\t\t<failure type="BuildFailure">%s</failure>\n'
                        '\t</testcase>\n' % (cloud, age))

    with open(RESULTS_FILENAME, 'w') as out:
        out.write('%s\n%s%s\n' % (header, content, footer))


def date_diff(first, second):
    """Difference between two dates."""
    first = datetime.strptime(first, '%Y%m%d')
    second = datetime.strptime(second, '%Y%m%d')
    return abs((first - second).days)


def call_image_status(cloud, stream, release):
    """Call the image_status script."""
    cmd = './image-status %s-%s release=%s json' % (cloud, stream, release)
    process = subprocess.Popen(shlex.split(cmd),
                               stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    out, _ = process.communicate()
    try:
        return json.loads(out.decode('utf8'))
    except json.decoder.JSONDecodeError:
        return None


def main(release, daily):
    """Determine oldest image age."""
    today = datetime.utcnow().strftime('%Y%m%d')
    stream = 'daily' if daily else 'release'
    print('%s %s image age on [%s]' % (release, stream, today))

    results = {}
    for cloud in SUPPORTED_CLOUDS:
        data = call_image_status(cloud, stream, release)
        if not data:
            print('%6s: ---' % cloud)
            results[cloud] = 'None'
        else:
            oldest_date = min(result['version_name'] for result in data)
            age = date_diff(today, oldest_date[:8])
            print('%6s: %3s [%s]' % (cloud, age, oldest_date))
            results[cloud] = age

    print_results(results)


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser()
    PARSER.add_argument('-d', '--daily', action='store_true',
                        help='Search daily versus release')
    PARSER.add_argument('release', nargs='?',
                        default=UbuntuDistroInfo().devel(),
                        help='Ubuntu release to search for')
    ARGS = PARSER.parse_args()

    if ARGS.release not in SUPPORTED_RELEASES:
        print('Invalid release, choose from: %s' % SUPPORTED_RELEASES)
        sys.exit(1)

    main(ARGS.release, ARGS.daily)
