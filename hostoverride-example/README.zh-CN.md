# OS_HOST_OVERRIDES 示例

[English](README.md) | **简体中文**

这个 fork 所带 `OS_HOST_OVERRIDES` 补丁的可运行示例:一次 Terraform 运行同时
对接两套 OpenStack 集群 —— 它们共用同一组内部服务域名,只有网关 IP 不同。

## 要解决的问题

OpenStack 的 API 网关**按 `Host` 头分流**。两套同样方式部署的集群,暴露出来的
是完全相同的名字:

```
hello.keystone.api      hello.nova.api      hello.neutron.api
```

区别只在网关 IP。`/etc/hosts` 表达不了这种情况 —— 一个域名只能指向一个地址。
也不能把 `auth_url` 直接写成 IP:那样网关收到的是 `Host: 192.0.2.10`,
根本不知道你要访问哪个服务。

需要的正是 `curl --resolve` 的语义:**保留 Host 头,只改拨号目标**。

## 怎么表达

在 `auth_url` 的主机名末尾加一个别名后缀,再用环境变量把后缀映射到地址:

```bash
export OS_HOST_OVERRIDES='.c1=192.0.2.10,.c2=198.51.100.20'
```

```hcl
auth_url = "http://hello.keystone.api.c1:80/v3"
```

这个后缀**不是真实域名**,永远不需要能解析。该 provider 客户端发出的每个请求:

| | 值 |
|---|---|
| 改写前 `URL.Host` | `hello.keystone.api.c1:80` |
| 实际拨号 | `192.0.2.10:80` |
| 发出的 `Host` 头 | `hello.keystone.api:80` |

后缀**只从主机名上剥**,端口原样保留。想让 `Host` 头里带 `:80`,`auth_url` 就得
显式写出来 —— 不写的话 Go 会省略默认端口,网关看到的是 `hello.keystone.api`。

认证之后这一点同样关键。服务目录返回的是**不带后缀的真实域名**
(`http://hello.nova.api:80/v2.1/...`),它们本来就带着正确的 `Host`,
改写器把它们拨向同一个地址。这也是为什么这个 override 绑在**单个 provider 的
HTTP 客户端**上,而不是做成全局域名映射 —— 全局映射匹配不上目录 URL,
又会退回去查 DNS。

## 覆盖的场景

`main.tf` 把五种接入方式并排放在一起。**只有第一种需要这个 fork**,
其余四种和官方 provider 的行为完全一致。

| # | provider alias | `auth_url` | 补丁参与 | HTTPS |
|---|---|---|---|---|
| A | `alias_c1` / `alias_c2` | `http://hello.keystone.api.c1:80/v3` | **是** | 不行 —— 见「限制」 |
| B | `public_dns` | `https://keystone.example.com:5000/v3` | 否 | 可以 |
| C | `hosts_file` | `http://keystone.internal.lan:5000/v3` | 否 | 可以 |
| D | `bare_ip` | `http://203.0.113.10:5000/v3` | 否 | 证书里得有 IP SAN 才行 |
| E | `https_selfsigned` | `https://keystone.internal.lan:5000/v3` | 否 | 可以,用 `cacert_file` 或 `insecure` |

**A — 别名后缀。** 这个 fork 存在的理由:两套集群、服务名完全相同、网关 IP 不同。

**B — 普通 DNS。** 没什么特别的。放进来是当**对照组**:哪怕 `OS_HOST_OVERRIDES`
在环境里设着(`run.sh` 就设着),它的主机名匹配不到后缀,RoundTripper 依然
原样返回。生效与否是**按每个 provider 的 `auth_url` 单独判断**的。

**C — `/etc/hosts`。** 配置形态和 B 完全一样 —— provider 根本不知道域名是谁解析的。
这也是和 A 最诚实的对比:`/etc/hosts` 是**一个域名对一个地址的全局映射**,
两套集群共用域名时你只能二选一,没法在同一次 apply 里都连上。
而且它是机器级配置、改它要 root、影响机器上所有程序;
`OS_HOST_OVERRIDES` 的作用域只在这一个进程内。

**D — 直接写 IP。** 没有主机名可匹配,补丁自然不参与。两个坑:`Host` 头会变成
IP,按 `Host` 分流的网关认不出来;以及认证成功后 gophercloud 走的是
**服务目录里的 URL**,如果 catalog 里登记的是域名,后续请求照样会去解析那些
域名 —— `auth_url` 写 IP 绕不开。

**E — HTTPS + 私有 CA。** 优先用 `cacert_file`(保留完整校验),
而不是 `insecure = true`(直接关掉校验)。两者二选一,别同时配。

## 文件

```
main.tf                   两套带后缀的集群,外加一个普通用法
variables.tf              认证信息全用变量,不带默认值
terraform.tfvars.example  复制成 terraform.tfvars 后填写
run.sh                    设置 OS_HOST_OVERRIDES 并清掉代理变量
```

## 运行

```bash
cp terraform.tfvars.example terraform.tfvars   # 填入真实取值
$EDITOR run.sh                                 # 换成你自己的网关 IP
terraform init
./run.sh plan
```

如果你已经配了 dev override,`terraform init` 不会去下载这个 provider ——
见 [../build.zh-CN.md](../build.zh-CN.md)。

## 几个值得注意的点

**每个资源都显式写了 `provider =`。** 这个示例**故意没有**默认(无 alias)
provider。漏写时会在 plan 阶段直接报 `Provider configuration not present`,
而不是静默落到某个默认集群上 —— 多集群环境里,后者是最糟糕的失败模式:
不报错,只是建到了别的集群。

**补丁是按 provider 选择性生效的。** `main.tf` 里第三个 provider 用的是普通域名、
没有后缀,主机名匹配不到任何条目,RoundTripper 会被原样返回 —— 走的就是上游
代码路径。普通域名和裸 IP 的行为和官方 provider **完全一致**。

**必须清掉代理变量。** `HTTP_PROXY` 一旦生效,请求会先发给代理,拨号目标的改写
就白做了。`run.sh` 里已经 unset。

## 限制

改写的是 `URL.Host`,所以在 HTTPS 下,SNI 和证书校验拿到的是 IP 而不是真实
主机名。**带后缀的端点目前只能用纯 HTTP**。不带后缀的 provider 不受影响,
可以正常使用 HTTPS。
