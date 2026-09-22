# Building this fork

**English** | [简体中文](build.zh-CN.md)

This fork exists for one reason: it wires in a patched `gophercloud/utils`
that adds `OS_HOST_OVERRIDES`, so a single Terraform run can talk to several
OpenStack clusters that share the same internal service domain names and
differ only by gateway IP (the semantics of `curl --resolve`).

The patch itself is **not in this repo**. It lives in a fork of
`gophercloud/utils`, on branch `host-override`.

## Layout

Both repos must sit side by side, because `go.mod` uses a relative replace:

```
<workspace>/
├── terraform-provider-openstack/   # this repo, branch hostoverride-v2.1.0
└── gophercloud-utils/              # the fork,  branch host-override
```

```
go.mod:  replace github.com/gophercloud/utils => ../gophercloud-utils
```

The import path stays `github.com/gophercloud/utils` — that is the module
identity, and the `replace` is what redirects it. Do not rename it.

## One-time setup

Clone both repos into the same parent directory. `~/workspace` is only an
example — any directory works, as long as the two end up as siblings.

```bash
mkdir -p ~/workspace && cd ~/workspace

# 1. the patched gophercloud/utils fork — this is where the patch lives
git clone -b host-override https://github.com/yimtun/gophercloud-utils.git

# 2. this repo
git clone -b hostoverride-v2.1.0 https://github.com/yimtun/terraform-provider-openstack.git
```

Both repos are public, so HTTPS needs no credentials — handy on a machine that
has no SSH key set up. Use SSH instead if you intend to push:

```bash
git clone -b host-override git@github.com:yimtun/gophercloud-utils.git
git clone -b hostoverride-v2.1.0 git@github.com:yimtun/terraform-provider-openstack.git
```

`-b` puts each clone straight onto the right branch, so there is no separate
checkout step. Both land in directories named after the repo, so the sibling
layout above comes out right without passing an explicit target directory.

Check the result before building — a wrong layout compiles fine against the
upstream module and silently produces a binary without the patch:

```bash
cd ~/workspace/terraform-provider-openstack
git branch --show-current                              # hostoverride-v2.1.0
grep -n '^replace' go.mod                              # => ../gophercloud-utils
ls ../gophercloud-utils/terraform/auth/hostoverride.go # must exist
```

`hostoverride-v2.1.0` is cut from tag `v2.1.0`. Keep it there — `main` tracks
upstream and is thousands of commits ahead, while the consuming Terraform
config pins 2.1.0.

If you also want to follow upstream in the utils fork:

```bash
cd ~/workspace/gophercloud-utils
git remote add upstream https://github.com/gophercloud/utils.git
```

Do not rebase `host-override` onto it — see the table at the end.

## Build

```bash
go build -o terraform-provider-openstack .
```

That is all. Takes about a minute once the module cache is warm.

**The first build on a fresh machine needs network access.** Only the patched
`gophercloud/utils` comes from the relative replace; every other dependency is
downloaded through `GOPROXY`. After that first run the module cache covers it
and rebuilds work offline.

If `proxy.golang.org` is unreachable from your network, either point `GOPROXY`
at a reachable mirror, or fetch straight from the source repos:

```bash
export GOPROXY=https://goproxy.cn,direct   # or any mirror you can reach
# or
export GOPROXY=direct GOSUMDB=off
```

Warming the cache separately, so a failure here is not confused with a build
error:

```bash
go mod download
```

If `go` is not on your PATH, add it first:

```bash
export PATH=<go-install-dir>/bin:$PATH
go version      # expect go1.25.x
```

## Use it

Terraform picks the binary up through a dev override rather than the registry,
so there is no `terraform init` step for the provider:

```hcl
# ~/.terraformrc
provider_installation {
  dev_overrides {
    "terraform-provider-openstack/openstack" = "<workspace>/terraform-provider-openstack"
  }
  direct {}
}
```

Every plan then prints `Provider development overrides are in effect` — that
warning is expected and confirms the local binary is being used. The
`version = "2.1.0"` constraint in the Terraform config is **not** enforced
while an override is active.

## Verify the patch is actually in the binary

Building successfully does not prove the patch got linked in — a stale
`replace` path would still compile against the upstream module. Check
functionally: point a provider at an alias suffix and see whether it connects.

```bash
export OS_HOST_OVERRIDES='.c1=192.0.2.10'
# auth_url = "http://keystone.openstack.svc.cluster.local.c1/v3"
terraform plan
```

- authenticates            → patch is in
- `no such host`           → patch is missing, or the env var was not exported

Note that `.c1` is not a real domain. The patched transport strips the suffix
from the `Host` header and dials the mapped address instead, which is why this
works without touching `/etc/hosts`.

A runnable configuration doing exactly this — plus four contrasting scenarios
that do *not* use the patch (public DNS, `/etc/hosts`, a bare IP, HTTPS with a
private CA) — lives in [hostoverride-example/](hostoverride-example/).

## Rollback

Keep a copy of the previous binary before rebuilding:

```bash
cp terraform-provider-openstack /tmp/provider.bak
```

Restoring is just copying it back — the binary is statically linked and does
not read the source tree at runtime.

## Things that do not work

Each of these was tried and rejected for a concrete reason:

| Attempt | Why it fails |
|---|---|
| `replace ... => github.com/yimtun/gophercloud-utils` | A module path on the right side requires a version. Only filesystem paths may omit it. |
| `replace ... => github.com/yimtun/gophercloud-utils v0.0.0-…` | The fork's `go.mod` declares `module github.com/gophercloud/utils`. Go rejects the mismatch. |
| Renaming `module` in the fork to fix the above | Cascades to 43 self-imports, one of which is an `internal/` package — those cannot be imported across module boundaries. |
| Rebasing `host-override` onto upstream `main` | Upstream moved the whole `terraform/` package out to `terraform-provider-openstack/utils`. The patch would have nothing to apply to. Being ~135 commits behind is correct: it tracks the revision this provider depends on. |

## Known limitation

The override rewrites `URL.Host`, so under HTTPS the SNI and certificate check
see the IP instead of the real hostname. Only plain HTTP endpoints work today.
Fixing it means moving the rewrite into a custom `DialContext`.
