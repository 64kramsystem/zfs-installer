#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

if [[ ! -e /opt/shellcheck/shellcheck ]]; then
  mkdir -p /opt/shellcheck

  wget -qO- https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz \
    | tar xJv -O shellcheck-stable/shellcheck \
    > /opt/shellcheck/shellcheck

  chmod +x /opt/shellcheck/shellcheck
fi

/opt/shellcheck/shellcheck --version

grep -lZP '^#!/bin/\w+sh' -R | xargs -0 /opt/shellcheck/shellcheck
