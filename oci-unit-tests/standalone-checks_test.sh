# shellcheck shell=dash

# shellcheck disable=SC1090
. "$(dirname "$0")/helper/test_helper.sh"
. "$(dirname "$0")/helper/common_vars.sh"

# cheat sheet:
#  assertTrue $?
#  assertEquals ["explanation"] 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

# Standalone checks that will be performed for each image.

# Check that all supported architectures are present in the manifest
# list for every image.
test_all_supported_architectures_are_available()
{
    # We only support querying AWS for now.
    local registries="aws"
    local namespaces="ubuntu lts"
    local utilsdir
    local listed_architectures
    local images_list
    # Which tags to test.
    local tags_regex='\(latest\|beta\|edge\)'
    local ret=0

    utilsdir="$(mktemp -d)/utils"
    trap 'rm -rf ${utilsdir}' 0 INT QUIT ABRT PIPE TERM

    debug "Checking if all supported architectures are present in the manifest list of each image"

    if ! git clone -q --depth 1 https://git.launchpad.net/~canonical-server/ubuntu-docker-images/+git/utils "${utilsdir}"; then
	debug "failed to clone 'utils' repository"
	exit 1
    fi

    # Iterate over the available registries...
    for registry in ${registries}; do
        # ... and over the available namespaces...
        for namespace in ${namespaces}; do
            # ... and over the list of all images for the
            # registry/namespace combination...
            images_list=$("${utilsdir}"/list-all-images.sh \
                                       --registry "${registry}" \
                                       --namespace "${namespace}")
            if [ "${DOCKER_PACKAGE}" != "$(basename "$0" | sed 's@\(.*\)_test\.sh@\1@')" ]; then
                # If the user has specified an image name to be tested, then
                # we just test it.
                if ! images_list=$(echo "${images_list}" | grep -Fw "${DOCKER_PACKAGE}"); then
                    continue
                fi
            fi
            for image in ${images_list}; do
                # ... and over the list of all available tags for each
                # image...
                for tag in $("${utilsdir}"/list-tags-for-image.sh \
                                          --registry "${registry}" \
                                          --namespace "${namespace}" \
                                          --image "${image}" \
                                 | grep "${tags_regex}"); do
                    debug "Checking manifest list for ${namespace}/${image}:${tag} on ${registry}"
                    # Obtain the manifest list for the current tag,
                    # and filter out everything but the published
                    # architectures.
                    listed_architectures=$("${utilsdir}"/list-manifest-for-image-and-tag.sh \
					                --registry "${registry}" \
					                --namespace "${namespace}" \
					                --image "${image}" \
					                --tag "${tag}" \
			                       | jq -r '.manifests[].platform.architecture')
                    if [ -z "${listed_architectures}" ]; then
                        # Check if we've gotten a valid output from
                        # the commands above.  Albeit rare, it is
                        # possible that the manifest list comes out empty.
                        echo "E: Could not obtain manifest list for ${namespace}/${image}:${tag} on ${registry}" > /dev/stderr
                        ret=1
                        continue
                    fi
                    for arch in ${SUPPORTED_ARCHITECTURES}; do
	                if ! echo "${listed_architectures}" | grep -Fwq "${arch}"; then
	                    echo "E: architecture '${arch}' not found in the manifest list of ${namespace}/${image}:${tag} on ${registry}" > /dev/stderr
	                    ret=1
	                else
                            debug "architecture '${arch}' successfully found in the manifest list of ${namespace}/${image}:${tag} on ${registry}"
                        fi
                    done
                done
            done
        done
    done

    rm -rf "${utilsdir}"

    assertTrue "Not all supported architectures are available" "$ret"
}

load_shunit2
