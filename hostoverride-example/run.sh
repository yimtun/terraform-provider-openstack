#!/bin/bash
# Wraps terraform so OS_HOST_OVERRIDES and the proxy settings are applied once.
#
#   ./run.sh plan
#   ./run.sh apply
#
# Calling terraform directly fails with "no such host", because the alias
# suffix in auth_url has nothing to map it to. That error gives no hint that a
# missing environment variable is the cause, so route everything through here.
set -euo pipefail

# alias suffix -> cluster gateway. The suffixes must match the ones used in the
# auth_url values in main.tf. These are RFC 5737 documentation addresses;
# replace them with your own gateways.
# The port is optional (80 by default); write .c1=192.0.2.10:8080 to set it.
export OS_HOST_OVERRIDES='.c1=192.0.2.10,.c2=198.51.100.20'

# Internal addresses must not go through a proxy. With HTTP_PROXY set the
# request is handed to the proxy first and the dial-target rewrite never takes
# effect.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

exec terraform "$@"
