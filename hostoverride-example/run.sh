#!/bin/bash
# Wraps terraform so OS_HOST_OVERRIDES, the provider override and the proxy
# settings are applied once.
#
#   ./run.sh plan
#   ./run.sh apply
#
# Calling terraform directly fails with "no such host", because the alias
# suffix in auth_url has nothing to map it to. That error gives no hint that a
# missing environment variable is the cause, so route everything through here.
set -euo pipefail

cd "$(dirname "$0")"

# --- which provider binary -------------------------------------------------
# Terraform cannot be told this from a .tf file; it is CLI configuration.
# A ./terraformrc here takes effect for this directory only, leaving the
# global ~/.terraformrc untouched. Without one, Terraform falls back to the
# usual lookup (global config, then the registry).
if [ -f ./terraformrc ]; then
  export TF_CLI_CONFIG_FILE="$PWD/terraformrc"
  echo "provider override: $TF_CLI_CONFIG_FILE" >&2
fi

# --- which cluster each alias suffix points at -----------------------------
# The suffixes must match the ones used in the auth_url values in main.tf.
# These are RFC 5737 documentation addresses; replace them with your own
# gateways. The port is optional (80 by default): .c1=192.0.2.10:8080
export OS_HOST_OVERRIDES='.c1=192.0.2.10,.c2=198.51.100.20'

# --- no proxy for internal addresses ---------------------------------------
# With HTTP_PROXY set the request is handed to the proxy first and the
# dial-target rewrite never takes effect.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

exec terraform "$@"
