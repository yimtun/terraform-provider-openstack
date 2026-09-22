# OS_HOST_OVERRIDES example

**English** | [简体中文](README.zh-CN.md)

A runnable example of the `OS_HOST_OVERRIDES` patch this fork carries: one
Terraform run talking to two OpenStack clusters that share the same internal
service domain names and differ only by gateway IP.

## The problem

An OpenStack API gateway routes by `Host` header. Two clusters deployed the
same way expose the same names:

```
hello.keystone.api      hello.nova.api      hello.neutron.api
```

Only the gateway IP differs. `/etc/hosts` cannot express that — one name, one
address. Nor can you just point `auth_url` at the IP: the gateway would then
see `Host: 192.0.2.10` and have no idea which service you mean.

What is needed is `curl --resolve`: keep the `Host` header, change only where
the connection is dialed.

## How it is expressed

Append an alias suffix to the hostname in `auth_url`, and map that suffix to an
address in the environment:

```bash
export OS_HOST_OVERRIDES='.c1=192.0.2.10,.c2=198.51.100.20'
```

```hcl
auth_url = "http://hello.keystone.api.c1:80/v3"
```

The suffix is **not a real domain** and never has to resolve. On every request
from that provider's client:

| | value |
|---|---|
| `URL.Host` before | `hello.keystone.api.c1:80` |
| dialed | `192.0.2.10:80` |
| `Host` header sent | `hello.keystone.api:80` |

The suffix is stripped from the hostname only; the **port is preserved**. Write
`:80` explicitly if you want it in the `Host` header — Go omits the default
port otherwise, and the gateway would see `hello.keystone.api`.

This matters after authentication too. The service catalog hands back the real
undecorated domains (`http://hello.nova.api:80/v2.1/...`); those already carry
the correct `Host`, and the rewriter dials them to the same address. That is why
the override is bound to one provider's HTTP client rather than being a global
name mapping — a global map would not match the catalog URLs and would fall
back to DNS.

## Scenarios covered

`main.tf` puts five ways of reaching a cluster side by side. Only the first one
needs this fork; the rest behave exactly as they do with the official provider.

| # | provider alias | `auth_url` | patch involved | HTTPS |
|---|---|---|---|---|
| A | `alias_c1` / `alias_c2` | `http://hello.keystone.api.c1:80/v3` | **yes** | no — see Limitation |
| B | `public_dns` | `https://keystone.example.com:5000/v3` | no | yes |
| C | `hosts_file` | `http://keystone.internal.lan:5000/v3` | no | yes |
| D | `bare_ip` | `http://203.0.113.10:5000/v3` | no | only if the cert carries an IP SAN |
| E | `https_selfsigned` | `https://keystone.internal.lan:5000/v3` | no | yes, via `cacert_file` or `insecure` |

**A — alias suffix.** The case this fork exists for: two clusters, identical
service names, different gateway IPs.

**B — ordinary DNS.** Nothing special. Worth having in the file as the control:
the suffix does not match, so the RoundTripper is returned unwrapped even
though `OS_HOST_OVERRIDES` is set in the environment. Opting in is per
provider, decided from each `auth_url`.

**C — `/etc/hosts`.** Configured identically to B; the provider never knows who
resolved the name. This is also the honest comparison for A: `/etc/hosts` is a
single global name-to-address mapping, so with two clusters sharing names you
must pick one — they cannot both be reached in one apply. It is also
machine-wide and needs root, while `OS_HOST_OVERRIDES` is scoped to one
process.

**D — bare IP.** No hostname, so nothing to match. Two caveats: the `Host`
header becomes the IP, which a gateway that routes by `Host` will not
recognise; and after authentication gophercloud follows the **service catalog**
URLs, so if the catalog registers domain names, later calls resolve those names
regardless of what `auth_url` said.

**E — HTTPS with a private CA.** Prefer `cacert_file`, which keeps full
verification, over `insecure = true`, which disables it. Set one, not both.

## Files

```
main.tf                   two clusters via alias suffixes, plus a plain one
variables.tf              credentials as variables, no defaults
terraform.tfvars.example  copy to terraform.tfvars and fill in
run.sh                    sets OS_HOST_OVERRIDES and clears proxy vars
```

## Running

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in real values
$EDITOR run.sh                                 # set your real gateway IPs
terraform init
./run.sh plan
```

`terraform init` will not fetch this provider if you have the dev override
configured — see [../build.md](../build.md).

## What to notice

**Every resource names its provider.** This example deliberately has no default
(unaliased) provider. Omitting `provider =` then fails at plan time with
`Provider configuration not present`, instead of silently landing on whichever
cluster happens to be the default. In a multi-cluster setup that silent landing
is the worst failure mode there is.

**The patch is opt-in per provider.** The third provider in `main.tf` uses an
ordinary domain with no suffix. Its hostname matches no entry, so the
RoundTripper is returned unwrapped — the upstream code path, byte for byte.
Plain domains and bare IPs keep working exactly as they do with the official
provider.

**Proxy variables must be cleared.** With `HTTP_PROXY` set, requests go to the
proxy first and the dial-target rewrite never takes effect. `run.sh` unsets
them.

## Limitation

The rewrite changes `URL.Host`, so under HTTPS the SNI and certificate check
see the IP rather than the real hostname. Suffixed endpoints must be plain HTTP
today. Providers **without** a suffix are unaffected and may use HTTPS freely.
