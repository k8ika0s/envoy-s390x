#!/usr/bin/env bash
#
# Wraps a test invocation in docker.

set -e
IMAGE=$1
RUN_REMOTE=$2
LOCAL_MOUNT=$3
DOCKER_ENV=$4
TEST_PATH=$(realpath "$5")
shift 5

if [ "${RUN_REMOTE}" == "yes" ]; then
  echo "Using docker environment from ${DOCKER_ENV}:"
  cat "${DOCKER_ENV}"
fi
# shellcheck disable=SC1090
. "${DOCKER_ENV}"

CONTAINER_NAME="envoy-test-runner"
ENVFILE=$(mktemp -t "bazel-test-env.XXXXXX")
function cleanup() {
  rm -f "${ENVFILE}"
  if [ "${RUN_REMOTE}" == "yes" ]; then
    docker rm -f "${CONTAINER_NAME}"  || true # We don't really care if it fails.
  fi
}

trap cleanup EXIT

cat > "${ENVFILE}" <<EOF
TEST_WORKSPACE=/tmp/workspace
TEST_SRCDIR=/tmp/src
ENVOY_IP_TEST_VERSIONS=v4only
EOF

CMDLINE="set -a && . /env && env && /test $*"

case "$(uname -m)" in
  x86_64)
    LIB_PATHS=(/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64)
    ;;
  aarch64|arm64)
    LIB_PATHS=(/lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu /lib64)
    ;;
  s390x)
    LIB_PATHS=(/lib/s390x-linux-gnu /usr/lib/s390x-linux-gnu /lib64)
    ;;
  ppc64le)
    LIB_PATHS=(/lib/powerpc64le-linux-gnu /usr/lib/powerpc64le-linux-gnu /lib64)
    ;;
  *)
    LIB_PATHS=(/lib64 /usr/lib64 /lib /usr/lib)
    ;;
esac

# Keep mounts/copies to paths that actually exist on this host.
EXISTING_LIB_PATHS=()
for path in "${LIB_PATHS[@]}"; do
  if [ -d "${path}" ]; then
    EXISTING_LIB_PATHS+=("${path}")
  fi
done


if [ "${RUN_REMOTE}" != "yes" ]; then
  # We're running locally. If told to, mount the library directories locally.
  LIB_MOUNTS=()
  if [ "${LOCAL_MOUNT}" == "yes" ]
  then
    for path in "${EXISTING_LIB_PATHS[@]}"; do
      LIB_MOUNTS+=(-v "${path}:${path}:ro")
    done
  fi

  docker run --rm --privileged  -v "${TEST_PATH}:/test" "${LIB_MOUNTS[@]}" -i -v "${ENVFILE}:/env" \
    "${IMAGE}" bash -c "${CMDLINE}"
else
  # In this case, we need to create the container, then make new layers on top of it, since we
  # can't mount everything into it.
  docker create -t --privileged  --name "${CONTAINER_NAME}" "${IMAGE}" \
    bash -c "${CMDLINE}"
  docker cp "$TEST_PATH" "${CONTAINER_NAME}:/test"
  docker cp "$ENVFILE" "${CONTAINER_NAME}:/env"

  # If some local libraries are necessary, copy them over.
  if [ "${LOCAL_MOUNT}" == "yes" ]; then
    for path in "${EXISTING_LIB_PATHS[@]}"; do
      # $path/. copies only the directory contents into the destination path.
      # destination directory, not overwrite the entire directory.
      docker cp -L "${path}/." "${CONTAINER_NAME}:${path}"
    done
  fi

  docker start -a "${CONTAINER_NAME}"
fi
