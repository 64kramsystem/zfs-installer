#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

ci/run_shellcheck mkdir -p /opt/shellcheck
[[ ! -e /opt/shellcheck/shellcheck ]] && wget -qO- https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz
  | tar -xJv -O shellcheck-stable/shellcheck | sudo tee /opt/shellcheck/shellcheck
  > /dev/null || true
sudo chmod +x /opt/shellcheck/shellcheck
/opt/shellcheck/shellcheck --version
/opt/shellcheck/shellcheck $(grep -lzP '^#!/bin/\\w+sh' -r .)
