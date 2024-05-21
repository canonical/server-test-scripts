#!/usr/bin/env python3

import sys

from subprocess import check_output, call

# to differentiate in jenkins between a failure in executing this script, and a
# "script worked fine, but there is action needed" situation
JENKINS_UNSTABLE_RETURN = 99

try:
    from launchpadlib.launchpad import Launchpad
except ImportError:
    print("Failed to import launchpadlib. Please install python3-launchpadlib")
    sys.exit(1)


class RmadisonPackage(object):
    def __init__(self, package):
        self.package = package
        self.rmadison = self._get_rmadison()

    def _get_rmadison(self):
        cmd = ["rmadison", "-asource", self.package]
        return self._parse_rmadison(check_output(cmd))

    def _parse_rmadison(self, data):
        pocket_version = {}
        for line in data.decode("utf-8").split("\n"):
            if not line:
                continue
            _, version, pocket, _ = [x.strip() for x in line.split("|")]
            pocket_version[pocket] = version
        return pocket_version

    def get_version(self, pocket):
        try:
            version = self.rmadison[pocket]
        except KeyError:
            version = None
        return version

    def get_latest_version_in_series(self, series):
        latest_version = (None, None)
        for pocket in [
            series,
            f"{series}-updates",
            f"{series}-security",
            f"{series}-proposed",
        ]:
            if pkg_version_greater_than(
                self.get_version(pocket), latest_version[0]
            ):
                latest_version = (self.get_version(pocket), pocket)
        return latest_version


class CcachePPA(object):
    def __init__(self, lp, ppa_owner, ppa_name, package="openssh"):
        self.lp = lp
        self.package = package
        self.archive = self.lp.people[ppa_owner].getPPAByName(name=ppa_name)

    def get_latest_version_in_series(self, series):
        distro_series = self.lp.distributions["ubuntu"].getSeries(
            name_or_version=series
        )
        sources = self.archive.getPublishedSources(
            source_name=self.package,
            distro_series=distro_series,
            status="Published",
        )
        assert len(sources) == 1
        return sources[0].source_package_version.strip()


# avoiding a dependency on python3-apt
def pkg_version_greater_than(v1, v2):
    if not v1:
        return False
    if not v2:
        return True
    cmd = ["dpkg", "--compare-versions", v1, "gt", v2]
    ret = call(cmd)
    return ret == 0


def main():
    rc = 0
    lp = Launchpad.login_anonymously("ccache-check", "production")
    openssh_ppa_proposed = CcachePPA(
        lp, "canonical-server", "openssh-server-default-ccache-proposed"
    )
    openssh_ppa_release = CcachePPA(
        lp, "canonical-server", "openssh-server-default-ccache"
    )
    openssh_ppa_testing = CcachePPA(lp, "canonical-server", "openssh-server-default-ccache-testing")
    ppa_version = {}
    ppa_version["testing"] = openssh_ppa_testing.get_latest_version_in_series("jammy")
    ppa_version["proposed"] = openssh_ppa_proposed.get_latest_version_in_series("jammy")
    ppa_version["release"] = openssh_ppa_release.get_latest_version_in_series("jammy")

    openssh_archive = RmadisonPackage("openssh")
    latest_version_in_archive = openssh_archive.get_latest_version_in_series(
        "jammy"
    )

    print(f"Latest version in jammy is {latest_version_in_archive}")
    print()
    for pocket, version in ppa_version.items():
        print(f"Latest version in {pocket} ccache ppa is {version}")
        if pkg_version_greater_than(latest_version_in_archive[0], version):
            print(
                f"WARNING: Latest version in archive "
                f"({latest_version_in_archive[0]}) is higher than version "
                f"{version} from ppa {pocket}"
            )
            rc = JENKINS_UNSTABLE_RETURN
        print()
    if rc != 0:
        print("ACTION NEEDED")
        print("Please see Canonical Spec US066 for details")
    else:
        print("ALL GOOD")
    return rc


if __name__ == "__main__":
    sys.exit(main())
