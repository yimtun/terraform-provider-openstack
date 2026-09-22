# 构建这个 fork

[English](build.md) | **简体中文**

这个 fork 只为一件事存在:它接入了一个打过补丁的 `gophercloud/utils`,
该补丁提供 `OS_HOST_OVERRIDES` —— 让一次 Terraform 运行能同时对接多套
OpenStack 集群。这些集群共用同一组内部服务域名,只有网关 IP 不同
(语义等价于 `curl --resolve`)。

补丁本身**不在这个仓库里**,它在 `gophercloud/utils` 的一个 fork 的
`host-override` 分支上。

## 目录布局

两个仓库必须并排放置,因为 `go.mod` 用的是相对路径 replace:

```
<workspace>/
├── terraform-provider-openstack/   # 本仓库,分支 hostoverride-v2.1.0
└── gophercloud-utils/              # 补丁 fork,分支 host-override
```

```
go.mod:  replace github.com/gophercloud/utils => ../gophercloud-utils
```

import path 保持 `github.com/gophercloud/utils` 不变 —— 它是**模块身份**,
`replace` 的作用正是把它重定向到别处。不要改它。

## 一次性准备

把两个仓库克隆到同一个父目录下。`~/workspace` 只是举例,任何目录都行,
只要两者最终是兄弟目录。

```bash
mkdir -p ~/workspace && cd ~/workspace

# 1. 打过补丁的 gophercloud/utils fork —— 补丁在这里
git clone -b host-override https://github.com/yimtun/gophercloud-utils.git

# 2. 本仓库
git clone -b hostoverride-v2.1.0 https://github.com/yimtun/terraform-provider-openstack.git
```

两个仓库都是公开的,HTTPS 不需要任何凭证 —— 在没配 SSH key 的机器上很方便。
要推送的话改用 SSH:

```bash
git clone -b host-override git@github.com:yimtun/gophercloud-utils.git
git clone -b hostoverride-v2.1.0 git@github.com:yimtun/terraform-provider-openstack.git
```

`-b` 让克隆直接落到目标分支,不用再单独 checkout。两条命令都会生成以仓库名
命名的目录,所以不用显式指定目标目录,上面那个兄弟布局自然就成立了。

**构建前先检查布局** —— 路径不对时 `go build` 会退回去用上游模块,
照样编译成功,只是**静默产出一个没有补丁的二进制**:

```bash
cd ~/workspace/terraform-provider-openstack
git branch --show-current                              # hostoverride-v2.1.0
grep -n '^replace' go.mod                              # => ../gophercloud-utils
ls ../gophercloud-utils/terraform/auth/hostoverride.go # 必须存在
```

`hostoverride-v2.1.0` 是从 tag `v2.1.0` 切出来的,**保持在这个位置**——
`main` 跟的是上游,已经领先几千个提交,而使用方的 Terraform 配置锁的是 2.1.0。

如果还想在 utils fork 里跟进上游:

```bash
cd ~/workspace/gophercloud-utils
git remote add upstream https://github.com/gophercloud/utils.git
```

但**不要**把 `host-override` rebase 到它上面 —— 原因见文末的表格。

## 构建

```bash
go build -o terraform-provider-openstack .
```

就这一条。模块缓存热起来之后约一分钟。

**新机器上的第一次构建需要联网。** 只有打补丁的 `gophercloud/utils` 走相对路径
replace,其余依赖都要通过 `GOPROXY` 下载。第一次跑完之后模块缓存就齐了,
后续重新构建可以完全离线。

如果你的网络连不上 `proxy.golang.org`,要么把 `GOPROXY` 指向一个能访问的镜像,
要么直接从源仓库拉:

```bash
export GOPROXY=https://goproxy.cn,direct   # 或任何你能访问的镜像
# 或者
export GOPROXY=direct GOSUMDB=off
```

建议单独预热缓存,免得把下载失败误判成编译错误:

```bash
go mod download
```

如果 `go` 不在 PATH 上,先加进去:

```bash
export PATH=<go安装目录>/bin:$PATH
go version      # 期望 go1.25.x
```

## 使用

Terraform 通过 dev override 拿这个二进制,不走 registry,所以 provider
没有 `terraform init` 这一步:

```hcl
# ~/.terraformrc
provider_installation {
  dev_overrides {
    "terraform-provider-openstack/openstack" = "<workspace>/terraform-provider-openstack"
  }
  direct {}
}
```

之后每次 plan 都会打印 `Provider development overrides are in effect` ——
这条警告是**预期的**,它恰好证明用的是本地二进制。注意:override 生效期间,
Terraform 配置里的 `version = "2.1.0"` 约束**不会**被强制执行。

## 验证补丁真的编进去了

编译成功**不能**证明补丁被链接进去了 —— replace 路径过期的话,它会照常
编译到上游模块上。要做功能验证:让 provider 使用一个别名后缀,看能不能连上。

```bash
export OS_HOST_OVERRIDES='.c1=192.0.2.10'
# auth_url = "http://keystone.openstack.svc.cluster.local.c1/v3"
terraform plan
```

- 能认证成功        → 补丁在
- `no such host`   → 补丁没进去,或者环境变量没有 `export`

注意 `.c1` 不是真实域名。打过补丁的传输层会把这个后缀从 `Host` 头里剥掉,
转而拨向映射到的地址 —— 这就是它不需要动 `/etc/hosts` 的原因。

把这件事跑起来的完整配置在 [hostoverride-example/](hostoverride-example/) ——
里面还并排放了四种【不走补丁】的场景作对照:公网 DNS、`/etc/hosts`、直接写 IP、
HTTPS + 私有 CA。

## 回退

重新构建前先留一份旧二进制:

```bash
cp terraform-provider-openstack /tmp/provider.bak
```

恢复就是拷回去。二进制是静态链接的,运行时不读源码目录。

## 走不通的几条路

下面每一条都实际试过并被否掉,各有明确原因:

| 尝试 | 为什么不行 |
|---|---|
| `replace ... => github.com/yimtun/gophercloud-utils` | 右边是模块路径时**必须带版本**,只有文件系统路径才能省略。 |
| `replace ... => github.com/yimtun/gophercloud-utils v0.0.0-…` | 该 fork 的 `go.mod` 声明的是 `module github.com/gophercloud/utils`,Go 会因路径不匹配直接拒绝。 |
| 改 fork 的 `module` 行来绕开上一条 | 会连锁影响 43 处 self-import,其中还有一个 `internal/` 包 —— 那类包无法跨模块边界引用。 |
| 把 `host-override` rebase 到上游 `main` | 上游已经把整个 `terraform/` 包搬到了 `terraform-provider-openstack/utils`,补丁将无处安放。落后约 135 个提交是**正确状态**:它跟的是本 provider 所依赖的那个版本。 |

## 已知限制

这个 override 改写的是 `URL.Host`,所以在 HTTPS 下,SNI 和证书校验拿到的是
IP 而不是真实主机名。目前只支持纯 HTTP 端点。要修的话,得把改写逻辑挪到
自定义的 `DialContext` 里。
