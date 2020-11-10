# Unit tests for OCI images

## Test definitions

Tests are written using the [shUnit2](https://github.com/kward/shunit2) unit
test framework for shell scripts. The tests cases are shell script compliant
with the `dash` implementation of `sh` (Ubuntu's default).

### Test dependencies

The tests should run on any Ubuntu >=Bionic system. Other than all the
`Priority: required` packages the tests can assume the following packages
an all of their dependencies are installed on the host system:

 - `ubuntu-server`
 - `docker.io`
 - `shunit2`

If a test requires specific dependencies they should be installed in a
dedicated Docker container.

### Port allocation

Many OCI unit tests require listening on local ports on the host system. Tests
should use ports in the
[Dynamic Ports range](https://tools.ietf.org/html/rfc6335#section-8.1.2)
(49152-65535). When writing a new tests care should be taken not to re-use a
port already used by another test.

## Jenkins

Jenkins jobs are defined in the `oci` directory of the
[server-jenkins-jobs](https://github.com/canonical/server-jenkins-jobs)
repository.
