## OS_HOST_OVERRIDES example — five ways of reaching a cluster, side by side.
##
## The patch is opt-in: it only engages when the hostname in auth_url matches a
## suffix listed in OS_HOST_OVERRIDES. Every other case takes the upstream code
## path untouched.
##
##   A. alias_c1 / alias_c2   alias suffix + OS_HOST_OVERRIDES   <- what this fork is for
##   B. public_dns            a name public DNS resolves, HTTPS
##   C. hosts_file            an internal name resolved via /etc/hosts
##   D. bare_ip               an IP, no hostname at all
##   E. https_selfsigned      HTTPS against a private CA
##
## Only A needs this fork. B through E behave exactly as they do with the
## official provider.
##
## Run with:  ./run.sh plan
## See also:  README.md  ·  README.zh-CN.md (中文)

terraform {
  required_version = ">= 1.5"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "2.1.0"
    }
  }
}

## ===========================================================================
## A. Alias suffix — two clusters sharing one set of service names
## ===========================================================================
## The API gateway routes by Host header, and both clusters expose identical
## names (hello.keystone.api, hello.nova.api, ...) behind different gateway
## IPs. /etc/hosts cannot express that (see scenario C), which is why this
## patch exists.
##
## Append the suffix .c1 to the hostname in auth_url. It is NOT a real domain
## and never has to resolve. The port goes after it: the rewriter strips the
## suffix from the hostname only and preserves the port.
##
##   URL.Host  hello.keystone.api.c1:80   ->  dials 192.0.2.10:80
##   Host header                              hello.keystone.api:80
##
## Plain HTTP only. The reason is spelled out in scenario E.
provider "openstack" {
  alias    = "alias_c1"
  auth_url = "http://hello.keystone.api.c1:80/v3"

  user_name        = var.c1_user_name
  password         = var.c1_password
  tenant_id        = var.c1_project_id
  user_domain_name = var.c1_user_domain

  # Pin the catalog endpoint type so OS_ENDPOINT_TYPE / OS_INTERFACE in the
  # environment cannot quietly redirect this provider to the admin URL.
  endpoint_type = "public"
}

## The second cluster — identical hostname, different suffix. This is precisely
## what /etc/hosts cannot do and this patch can.
provider "openstack" {
  alias    = "alias_c2"
  auth_url = "http://hello.keystone.api.c2:80/v3"

  user_name        = var.c2_user_name
  password         = var.c2_password
  tenant_id        = var.c2_project_id
  user_domain_name = var.c2_user_domain

  endpoint_type = "public"
}

## ===========================================================================
## B. A name public DNS resolves, over HTTPS — the ordinary case
## ===========================================================================
## The hostname matches no suffix, so wrapHostOverride returns the
## RoundTripper unwrapped and not a line of the patch executes. Name
## resolution, TLS handshake and certificate verification are stock Go.
##
## This holds even though run.sh exports OS_HOST_OVERRIDES: opting in is
## decided per provider, from each auth_url.
provider "openstack" {
  alias    = "public_dns"
  auth_url = "https://keystone.example.com:5000/v3"

  user_name        = var.c1_user_name
  password         = var.c1_password
  tenant_id        = var.c1_project_id
  user_domain_name = var.c1_user_domain

  endpoint_type = "public"
}

## ===========================================================================
## C. An internal name resolved through /etc/hosts
## ===========================================================================
## Configured exactly like B — the provider never learns who resolved the
## name. It calls Go's resolver, which consults /etc/hosts before DNS.
##
##   # /etc/hosts
##   203.0.113.10   keystone.internal.lan
##
## This is the honest comparison for scenario A. /etc/hosts is a single global
## name-to-address mapping: when two clusters share a name you must pick one,
## and they cannot both be reached in a single apply. It is also machine-wide
## and needs root, affecting every program on the host — whereas
## OS_HOST_OVERRIDES is scoped to this one process.
provider "openstack" {
  alias    = "hosts_file"
  auth_url = "http://keystone.internal.lan:5000/v3"

  user_name        = var.c1_user_name
  password         = var.c1_password
  tenant_id        = var.c1_project_id
  user_domain_name = var.c1_user_domain

  endpoint_type = "public"
}

## ===========================================================================
## D. A bare IP — no hostname involved
## ===========================================================================
## Nothing to match, so the patch stays out of the way. No DNS and no
## /etc/hosts entry required. Two caveats:
##
##   - The Host header becomes "203.0.113.10:5000". A gateway that routes by
##     Host will not recognise it — which is the very problem scenario A
##     solves.
##
##   - After authentication gophercloud follows the SERVICE CATALOG URLs. If
##     the catalog registers domain names, later nova/neutron calls resolve
##     those names regardless of what auth_url said. Check what the catalog
##     returns before assuming an IP here avoids DNS entirely.
provider "openstack" {
  alias    = "bare_ip"
  auth_url = "http://203.0.113.10:5000/v3"

  user_name        = var.c1_user_name
  password         = var.c1_password
  tenant_id        = var.c1_project_id
  user_domain_name = var.c1_user_domain

  endpoint_type = "public"
}

## ===========================================================================
## E. HTTPS against a private CA
## ===========================================================================
## Two options, most trustworthy first:
##
##   cacert_file  hand the signing CA to the provider; verification stays on
##   insecure     skip verification entirely — easy, but gives up MITM
##                protection
##
## cacert_file is shown; the insecure line is commented out. Set one, not both.
##
## WHY SCENARIO A CANNOT USE HTTPS
## The rewriter changes URL.Host, so the TLS handshake sees "192.0.2.10" for
## SNI and certificate verification instead of the real hostname. No
## certificate carries that name, and the handshake fails. Supporting HTTPS
## means moving the rewrite into a custom DialContext, where the TLS layer
## still sees the original hostname. That is a known, unfixed limitation.
##
## This scenario has no suffix, the patch does not participate, and HTTPS
## works normally.
provider "openstack" {
  alias    = "https_selfsigned"
  auth_url = "https://keystone.internal.lan:5000/v3"

  user_name        = var.c1_user_name
  password         = var.c1_password
  tenant_id        = var.c1_project_id
  user_domain_name = var.c1_user_domain

  # Path to the private CA certificate. Empty (the variable default) means the
  # argument has no effect and the system trust store is used.
  cacert_file = var.cacert_file

  # insecure = true   # the easy way out; mutually exclusive with cacert_file

  endpoint_type = "public"
}

## ===========================================================================
## Read-only verification
## ===========================================================================
## Every data source names its provider explicitly. This example deliberately
## has NO default (unaliased) provider: omitting `provider =` then fails at
## plan time with "Provider configuration not present", rather than silently
## landing on whichever cluster happens to be the default. In a multi-cluster
## setup that silent landing is the worst failure mode there is.
##
## Only the two from scenario A are wired up, so that plan can actually run.
## B through E point at example domains; swap in your own auth_url and add
## data sources the same way to exercise them.

data "openstack_networking_network_v2" "c1" {
  provider = openstack.alias_c1
  name     = var.network_name
}

data "openstack_networking_network_v2" "c2" {
  provider = openstack.alias_c2
  name     = var.network_name
}

output "c1_network_id" {
  description = "ID of that network on cluster one"
  value       = data.openstack_networking_network_v2.c1.id
}

output "c2_network_id" {
  description = "ID of the same-named network on cluster two"
  value       = data.openstack_networking_network_v2.c2.id
}
