<!--
  如果你 fork 或改名了这个仓库，请把全文里的
  Winter21c/immortalwrt-fusion 换成实际地址。
  FanchmWrt 的授权条款明确要求：再发布固件时必须附上其仓库地址。
-->

# ImmortalWrt 融合固件构建器

**以 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 为底座，在 GitHub Actions 上按需并入 [FanchmWrt](https://github.com/fanchmwrt/fanchmwrt) 或 [iStoreOS](https://github.com/istoreos/istoreos) 的特性，编完自动发 Release。**

面向 **x86_64**。底座 ImmortalWrt 25.12。

---

## 一句话理解

底座永远是 ImmortalWrt。上面有两个**各自独立的复选框**：

```
                    ┌─────────────────────────────────────┐
   ImmortalWrt  ────┤  ☑ FanchmWrt 特性   ☑ iStoreOS 特性  ├──── 固件
     底座           └─────────────────────────────────────┘
                                  │
              四种组合，主题与首页自动跟着变
```

| ☑ FanchmWrt | ☑ iStoreOS | 你得到 | 主题 / 首页 |
|:---:|:---:|---|---|
| ☑ | ☑ | 融合版：既有流量识别，又有应用商店 | FanchmWrt 主题 / FanchmWrt 仪表盘 |
| ☑ | ☐ | 纯 FanchmWrt 风味 | FanchmWrt 主题 / FanchmWrt 仪表盘 |
| ☐ | ☑ | 纯 iStoreOS 风味 | argon 主题 / QuickStart |
| ☐ | ☐ | 纯净 ImmortalWrt（只带底座增强） | ImmortalWrt 默认 |

> 「都不勾」也是一个合法选择，不是错误 —— 你会得到一份加了 mosdns、
> OpenClash、Web 终端和轻 NAS 套件的干净 ImmortalWrt。

---

## 🚀 怎么用

### 方式一：手动点一下（推荐）

1. 打开本仓库的 **Actions** 标签页
2. 左侧选「**构建 x86_64 固件**」
3. 右边 **Run workflow**，按需填：

| 参数 | 默认 | 说明 |
|---|---|---|
| `with_fanchmwrt` | ✅ | 并入 FanchmWrt 特性：fwx 应用识别、流量统计、行为管理、仪表盘、高级/普通模式 |
| `with_istoreos` | ✅ | 并入 iStoreOS 特性：QuickStart 首页、iStore 应用商店 |
| `lan_ip` | `192.168.1.1` | **管理地址**。可带前缀长度，如 `192.168.100.1/24` |
| `rootfs_size` | `1024` | **固件大小**（rootfs 分区 MB）：512 / 1024 / 2048 / 4096 / 8192 |
| `enable_docker` | ✅ | 包含 Docker（dockerd + docker-compose + Dockerman 界面） |
| `create_release` | ✅ | **构建成功后直接发 Release**（默认开） |
| `release_tag` | 留空 | 指定标签；留空则自动用 `日期-时间` |
| `upload_artifact` | ✅ | 同时上传成构建产物，Actions 页面可直接下载 |

4. 大约 **2 小时**后出结果（整棵 OpenWrt 在 4 核 runner 上约 2~3 小时，首次无缓存更久）

> 只要不勾 `create_release`，就只上传构建产物、不发 Release。

### 方式二：打个标签就自动发布

```sh
git tag v25.12.1-fusion.1
git push origin v25.12.1-fusion.1
```

编译完自动创建同名 Release。这条路径用默认参数（两个特性都要、含 Docker、192.168.1.1、1GB 分区）。

### 方式三：定时构建

工作流里带了一个**注释掉**的定时任务。想用就把 `schedule:` 那几行取消注释：

```yaml
  schedule:
    - cron: '0 18 * * 0'   # 每周日 18:00 UTC = 周一 02:00（UTC+8）
```

⚠️ **cron 是 UTC**。北京时间凌晨 2 点要写 `0 18 * * *`（前一天 18:00 UTC），
写 `0 2 * * *` 会在北京时间上午 10 点触发 —— 这是最常踩的坑。

它的用处是**提前发现上游腐烂**：v2ray-geodata 的规则数据 tag 只保留约三个月，
第三方 feed 也会变。每周跑一次能在用户之前发现，而不是等别人 clone 后构建失败来提 issue。

> GitHub 会在仓库**连续 60 天没有任何提交活动**后自动停用定时工作流，
> 需要在 Actions 页面手动重新启用。

---

## 📦 固件里到底有什么

### 底座层（永远都在）

| | 说明 |
|---|---|
| **mosdns** | 高性能 DNS 转发 / 分流，含 geoip / geosite 规则库 |
| **OpenClash** | 代理客户端。**只带界面，不含内核** —— 进 LuCI 点一下下载 mihomo 内核即可，也方便你换版本 |
| **ttyd** | 浏览器里的 Web 终端 |
| **DiskMan** | 磁盘分区、格式化、挂载、SMART |
| **NFS** | Linux / 虚拟机场景的网络文件系统 |
| **mergerfs** | 多块硬盘合并成一个池 |
| **UniShare** | SMB / WebDAV / NFS 统一共享管理 |
| **wsdd2** | 让 Windows 网络邻居能发现这台机器 |

**明确去掉的**：DDNS、硬盘休眠（hd-idle）、网络唤醒（WOL），
以及 Samba 的**配置界面**。

> ⚠️ 关于 SMB 要说清楚：去掉的是 **`luci-app-samba4` 这个网页界面**，
> 服务端 `samba4-server` 被 UniShare 依赖着保留在固件里，**SMB 共享照常可用**，
> 只是没有网页配置入口，要改配置得走 UniShare 或命令行。
> 这是你确认过的口径，不是遗漏。

### FanchmWrt 层（勾了才有）

| | 说明 |
|---|---|
| **fwx 应用识别** | 内核态 netfilter 模块，按应用/协议特征识别流量（DPI） |
| **fwxd** | 用户态守护进程，管特征库、会话与统计 |
| **17 个 `luci-app-fwx-*`** | 应用过滤、行为管理、MAC 黑白名单、上网记录、流量统计、在线用户、无线管理、应用中心等 |
| **`luci-theme-fanchmwrt`** | FanchmWrt 主题：仪表盘 + 菜单 + **高级 / 普通模式**开关 |

> ⚠️ **勾选这一层会改动内核**，这一点必须说清楚。
>
> fwx 不是普通的包：它的内核模块直接读写连接跟踪结构体 `struct nf_conn` 里
> 一个叫 `fwx_data` 的自定义字段，而这个字段是 FanchmWrt 自己给内核加的，
> ImmortalWrt 的内核里没有。所以本仓库带了一个内核补丁
> （`vendor/fanchmwrt/kernel-patches/950-fwx-nf-conn-struct-user-hook.patch`，
> 取自 fanchmwrt 的 `target/linux/generic/hack-6.12/`），
> **只在勾选 FanchmWrt 时装上，不勾时卸下**。
>
> 这是 fwx 的硬性前提，绕不过去 —— 尝试过直接编，失败信息是
> `error: 'struct nf_conn' has no member named 'fwx_data'`，
> 报错指向 fwx 的源码，根因却在内核侧。
>
> 换句话说：**这是本项目里唯一一处对底座的实质性改动**，其余全部是叠加。
> 不想动内核就不要勾这一层。

> **「高级 / 普通模式」不是独立功能，它实现在 FanchmWrt 主题的菜单脚本里。**
> 普通模式只显示 fwx 自己的菜单，高级模式才露出全部。所以「勾 FanchmWrt 就用
> FanchmWrt 主题」不是巧合，而是这两件事本来就是一件事。

> **fullcone NAT 不在这一层里。** ImmortalWrt 树内已经有 `fullconenat-nft`，
> 而且 `firewall4` 的依赖里就挂着它 —— 任何组合下都在，不需要我们重复带一份。

### iStoreOS 层（勾了才有）

| | 说明 |
|---|---|
| **QuickStart** | 首页快速设置面板：上网方式、网络状态、Wi-Fi 一页搞定 |
| **iStore 应用商店** | 图形化装插件，带教程与依赖解析，支持备份/恢复 |
| **argon 主题** | iStoreOS 的默认主题 |

### Docker 层（独立复选框）

`dockerd` + `docker` + `docker-compose` + Dockerman 图形界面。

**这里没有对 `dockerd` 打任何补丁**，这是核对过代码之后的决定，值得说清楚。

原本的计划是照搬 iStoreOS 的 dockerd 定制（关掉 docker 自带的 iptables、
改由 fw4 统一管）。实际去读 ImmortalWrt 自带的 `dockerd` 之后发现：

- ImmortalWrt 的 `dockerd.init` **自带** `uciadd` / `ucidel`，会创建 docker
  firewall zone、把接口加进去，并且在 `postinst` 里自动调用。
  它默认 `iptables='1'`，也就是让 docker 自己管 NAT。
- 也就是说两边的做法是**相反的**。把一套本来就能工作的机制拆掉换成另一套，
  收益不明而风险很实在。
- 版本也对不上：ImmortalWrt 是 `29.6.1`，那份定制针对 `27.3.1`，补丁打不上。

**能跟随底座的就跟随底座。** 保留下来的是两件与 dockerd 版本无关、
纯粹由 x86 镜像布局决定的事（在 `vendor/istoreos/package/docker-defaults`，
不修改上游任何文件）：

- **squashfs 镜像上把 docker 数据目录指到 `/overlay/upper`** ——
  否则 `overlay2` 存储驱动会因为 backing filesystem 是 overlay 而**拒绝启动**
  （ImmortalWrt 默认的 `/opt/docker/` 在 overlay 上，没做特殊处理）。
  ext4 镜像没有独立的 `/overlay/upper`，这种镜像保持默认值。
- **给容器日志封顶**（`log_driver='local'`）—— 上游默认的 `json-file`
  不轮转、不封顶，一个话多的容器能把盘写满，而写满之后的现象是
  「所有服务莫名其妙开始失败」，很难联想到是容器日志。

### 主题与首页的规则

| 勾选 | 主题 | 首页 |
|---|---|---|
| FanchmWrt（含同时勾 iStoreOS） | FanchmWrt 主题 | FanchmWrt 仪表盘（QuickStart 让到菜单第二位） |
| 只勾 iStoreOS | argon 主题 | QuickStart |
| 都不勾 | ImmortalWrt 默认 | ImmortalWrt 默认 |

实现方式：QuickStart 上游的菜单序号本来就是 `1`（打开就进快速设置页），
同时勾两个时把它压到 `2`，首页让给 FanchmWrt 仪表盘；只勾 iStoreOS 时
**保持上游原样**，不去动它。主题则由一个 `99_` 开头的 uci-defaults 在首次
启动时锁定，保证「勾什么就得到什么」。

---

## 🔄 上游更新怎么跟

三种上游，「会不会自动跟上」的答案不一样，分开说清楚：

| 上游 | 消费方式 | 上游更新后 | 我们要做什么 |
|---|---|---|---|
| **ImmortalWrt** | 构建时现拉 `openwrt-25.12` 分支 | **自动跟上** | 什么都不用做 |
| **iStoreOS 侧**（quickstart / store / NAS 套件 / argon） | feed，构建时 `feeds update` 拉分支最新 | **已选中包的内容自动跟上** | 通常不用；feed 里新增的包不会自己进来 |
| **FanchmWrt** | **vendored**（代码在 `vendor/` 里） | **不会自动跟** | 需要一次 review 过的同步 |

> **为什么 FanchmWrt 要 vendor 而不是也走 fetch**：它的 `kmod-fwx` 需要一处
> **内核改动**（给 `struct nf_conn` 加 `fwx_data` 字段），那个补丁必须和
> ImmortalWrt 的内核版本一起验证过才能用。直接构建时现拉上游，意味着上游
> 某天改了内核侧的东西、我们的构建就当场炸，而且没人看过 diff。

### 上游有更新时会发生什么

`.github/workflows/upstream-watch.yml` 每周一自动跑一次，只把**真正可行动**的
两件事当成变更：

1. **`vendor/fanchmwrt` 与上游不一致** → 自动开一个 PR，把差异清单放进描述里。
   PR 上会跑四种组合的配置回归检查，你只需要判断「这个改动要不要」。
2. **内核补丁不再能应用** → 自动开 Issue（已开则追加评论，不会每周刷一个新的）。
   这个优先级最高 —— 它会让所有人勾 FanchmWrt 的构建失败。

feed 的 SHA 只写进报告做记录，**不算变更** —— 它们本来就是滚动跟随的，
每周报一次「变了」纯属噪音。

### 想手动看一眼

```sh
./scripts/check-upstream.sh              # 检查并打印报告
./scripts/check-upstream.sh --deep       # 额外验证内核补丁仍能应用（慢）
./scripts/check-upstream.sh --apply-vendor   # 把上游变化写进 vendor/
```

退出码：`0` 无变化、`10` vendor 有更新、`20` 内核补丁打不上了。

### 想换上游版本

改 `upstreams.conf` 一处即可 —— 那是唯一的来源，构建脚本都读它：

```sh
IMMORTALWRT_REF=openwrt-25.12     # 换 tag 就能锁死版本，换取可复现
FANCHMWRT_REF=fanchmwrt-25.12.4   # 上游按 OpenWrt 版本开分支
```

临时试一个版本不用改文件：`IMMORTALWRT_REF=my-ref ./build.sh`（环境变量优先）。

### 上游新增了应用，会自动跟上吗

**会。** FanchmWrt 层的包清单不是写死的，而是构建时从 `vendor/` 枚举出来的
（`scripts/04-config.sh` 的 `enumerate_fanchmwrt_pkgs`）。上游新增一个
`luci-app-fwx-*`，同步进 `vendor/` 之后下一次构建就会自动编进去，不需要改
任何配置文件。

这一点很重要：写死的清单会**静默地**漏掉新应用 —— 构建成功、断言全过、
固件里却没有新功能，没有任何提示。

之所以这样做是安全的：`vendor/` 的内容不会自己变，上游更新走的是
`upstream-watch` 开的 PR，人工看过 diff 才合并。所以「自动跟上上游」不会
退化成「自动引入没看过的东西」。

---

## 🛠️ 自己编译

需要 Linux（推荐 Ubuntu 22.04+）、约 30GB 磁盘、能访问 GitHub 与 Go 模块代理。

```sh
git clone https://github.com/Winter21c/immortalwrt-fusion.git
cd immortalwrt-fusion

./build.sh                              # 默认：两个特性都要、含 Docker
./build.sh 12                           # 指定并发数

# 只要 iStoreOS
WITH_FANCHMWRT=0 ./build.sh

# 只要底座
WITH_FANCHMWRT=0 WITH_ISTOREOS=0 ENABLE_DOCKER=0 ./build.sh

# 自定义管理地址与固件大小
LAN_IP=192.168.100.1/24 ROOTFS_PARTSIZE=2048 ./build.sh

# 只做到准备就绪，不下载也不编译（几秒钟就能知道配置对不对）
SKIP_BUILD=1 ./build.sh
```

产物在 `openwrt/bin/targets/x86/64/`。

**环境变量**

| 变量 | 默认 | 说明 |
|---|---|---|
| `WITH_FANCHMWRT` | `1` | 是否并入 FanchmWrt 特性 |
| `WITH_ISTOREOS` | `1` | 是否并入 iStoreOS 特性 |
| `ENABLE_DOCKER` | `1` | 是否包含 Docker |
| `LAN_IP` | `192.168.1.1` | 管理地址，可带前缀长度 |
| `ROOTFS_PARTSIZE` | `1024` | rootfs 分区（MB） |
| `IMMORTALWRT_REF` | `openwrt-25.12` | ImmortalWrt 的分支或 tag |
| `SKIP_BUILD` | `0` | 只准备不编译 |
| `SKIP_FEEDS_UPDATE` | `0` | 复用已有 feeds，跳过 update |

> **国内网络提示**：脚本里设了 `CURL_OPTIONS="--speed-limit 51200 --speed-time 60"`。
> curl 默认没有速率下限，一个「能用但极慢」的镜像会让 `make download` **永久卡住**
> 而不是自动换源；加上这个之后，慢于 50 KB/s 持续 60 秒就放弃该镜像。

---

## 🔍 这套构建器是怎么组织的

```
immortalwrt-fusion/
├── build.sh                    统一入口（本地与 CI 走同一条路径）
├── feeds.conf.append           追加到 ImmortalWrt 的额外 feed
│
├── config/                     ← 可勾选就体现在这里
│   ├── 00-target.config          目标平台与出哪些镜像
│   ├── 10-base.config            底座层（永远拼进来）
│   ├── 20-fanchmwrt.config       FanchmWrt 层（勾了才拼）
│   ├── 30-istoreos.config        iStoreOS 层（勾了才拼）
│   └── 40-docker.config          Docker 层（勾了才拼）
│
├── scripts/
│   ├── lib.sh                    共用函数；布尔值在这里统一成 1/0
│   ├── 01-fetch.sh               取 ImmortalWrt 源码
│   ├── 02-feeds.sh               配置并安装 feed（含解除撞名）
│   ├── 03-overlay.sh             把三个特性层铺进源码树 + 打补丁
│   ├── 04-config.sh              拼 .config、跑 defconfig、**双向断言**
│   └── 09-verify.sh              编译后核验产物（对照固件真实包列表）
│
├── vendor/                     已经并进来的第三方代码
│   ├── fanchmwrt/                fwx 内核模块、fwxd、主题、17 个 LuCI 应用
│   └── istoreos/                 docker-defaults（镜像布局决定的默认值）
│
├── overlay/package/            本项目自己的包
│   └── build-defaults/          承载管理地址与主题锁定，随构建参数生成
│
└── patches/                    定点补丁
    ├── 0002-quickstart-menu-order.patch
    └── 0003-v2ray-geodata-rolling-releases.patch
```

### 三个值得说的设计取舍

**1. 特性选择走 `.config`，不改 `include/target.mk` 的 `DEFAULT_PACKAGES`。**

包清单写在配置文件里，勾了哪个层就拼哪个文件。看 `.config` 一眼就知道这个固件
是怎么来的。改 `target.mk` 是隐式的，隔一层就看不见了。

**2. 每个组合都做双向断言，失败就中止。**

只断言「该有的在」是不够的 —— 漏装会报错，但**多装不会**。
你明确说了不要 ddns / hd-idle / wol / smb 界面，那就必须同时断言
「这些东西确实不在」，否则某天某个 meta 包把它们拖进来，构建照样是绿的。
`scripts/04-config.sh` 在 defconfig 之后逐项核对，任何一项不符就拒绝出固件。

**3. 编译完还要再做一次核验，而且是对着固件里真实的包列表。**

`.config` 里写了 `=y` 却被依赖解析丢掉、或者装上又被冲突移除，都是
编译通过之后才会暴露的问题。`scripts/09-verify.sh` 拿
`bin/targets/x86/64/*.manifest`（固件里真实装了什么）去比对期望清单，
再加上镜像数量、sha256 校验和。

**4. fanchmwrt 的代码是 vendored 进来的，不是构建时去拉的。**

`vendor/fanchmwrt/` 里是 fwx 内核模块、fwxd、主题和 17 个 LuCI 应用的完整源码。
好处是构建不依赖上游分支的稳定性（上游 force-push 或删分支都不会影响这里），
而且内核模块万一需要针对 ImmortalWrt 的内核适配，可以直接在这里改。
代价是上游更新不会自动流进来 —— 要同步的话用
`scripts/check-upstream.sh`（见下面「上游更新怎么跟」）。

---

## ✅ 验证到什么程度

诚实地说清楚边界 —— 这个仓库里的每一条断言都是可复现的，不是「应该没问题」。

### 已经验证过的

四种勾选组合，各自拼出的 `.config` 都逐项核对过（`SKIP_BUILD=1 ./build.sh` 就能复现）：

| 勾选 | 必须在位 | 确认排除 | 主题 |
|---|---:|---:|---|
| FanchmWrt + iStoreOS + Docker | 56 项 | 7 项 | FanchmWrt ✅ |
| 只要 FanchmWrt | 42 项 | 23 项 | FanchmWrt ✅ |
| 只要 iStoreOS | 36 项 | 26 项 | Argon ✅ |
| 都不勾（纯底座） | 21 项 | 42 项 | 不锁，ImmortalWrt 默认 ✅ |

「确认排除」那一列不是凑数的 —— 它断言的是你明确说不要的东西
（ddns / hd-idle / wol / Samba 界面）**确实不在**。只断言「该有的在」是不够的：
漏装会报错，多装不会。

| 其他验证项 | 状态 |
|---|---|
| 镜像配置 | 断言 TARGZ / INITRAMFS / CPIOGZ 均为关，只出 4 个镜像 |
| 第三方 feed 与底座撞名 | 剪枝 + 索引重建，实测剪掉 `luci-app-cpufreq` |
| vendored 包与树内重名 | 铺装前拦截（实测拦下 `fullconenat` / `fullconenat-nft`） |
| **完整编译（FanchmWrt + iStoreOS + Docker）** | ✅ 通过，零错误 |
| 编译后固件里真实的包列表 | ✅ 对照 `*.manifest` 核对：513 个包，该有的都在、不要的都不在 |
| 镜像数量与 sha256 校验和 | ✅ 4 个镜像，校验和全部通过 |
| **DPI 内核模块编到 ImmortalWrt 内核上** | ✅ 固件里是 `kmod-fwx 6.12.108-r1`，`.ko` 落在 `lib/modules/6.12.108/fwx.ko` |
| **QEMU/KVM 真启动** | ✅ 引导正常，`fwx` 模块加载成功（`fwx: init ok`），LuCI 返回 HTTP 200 |
| 启动后的实际状态 | ✅ fwxd / uhttpd 运行中，主题 = fanchmwrt，LAN = 192.168.1.1/24 且路由正确，Docker 29.6.1 存储驱动 overlayfs |

完整编译的实测数据（版本、大小、耗时）见
[docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) 第 5 节。

> 前两次编译是**失败的**，而且失败得有价值 —— 它们暴露了两个只看代码绝对
> 发现不了的问题：fwx 需要一处内核改动、mosdns 的二进制与界面必须成对。
> 两个问题的完整排查过程都记在 BUILD-NOTES 里。

### 没法在这里验证的

**已在 QEMU/KVM 里真实启动验证过**（引导、fwx 模块加载、主题、LAN 路由、
LuCI 访问、Docker 全部正常，见 docs/BUILD-NOTES.md 5.5）。

但 QEMU 不是真机，以下仍需你自己确认：

- 能否正常启动、LuCI 能否打开
- FanchmWrt 主题与仪表盘是否生效、**高级 / 普通模式**能否切换
- QuickStart 是否真的是首页
- **fwx 内核模块能否加载** —— 这一版改过内核，这是第一件要确认的事
- Docker 能否起来、存储驱动是否为 `overlay2`
- mosdns / OpenClash 的服务状态

刷机后建议先跑这几条：

```sh
# 1. 内核模块加载了吗（勾了 FanchmWrt 才有）
lsmod | grep fwx
dmesg | grep -i fwx | tail -20

# 2. 服务状态
/etc/init.d/fwxd status 2>/dev/null
/etc/init.d/mosdns status 2>/dev/null
/etc/init.d/dockerd status 2>/dev/null
docker info 2>/dev/null | grep -i "storage driver"

# 3. 这次固件是用什么参数编的
cat /etc/build-options

# 4. 管理地址、掩码与路由
#    ⚠️ 重点看掩码：应该是 /24，不是 /32。
#    如果是 /32，说明管理地址丢了前缀长度，路由器连不上局域网设备。
uci get network.lan.ipaddr
ip -4 addr show br-lan | grep inet
ip route | grep br-lan            # 应有 192.168.1.0/24 dev br-lan

# 5. 主题
uci get luci.main.mediaurlbase    # 勾了 FanchmWrt 应是 /luci-static/fanchmwrt
```

> 第 4 条那个 `/32` 是真踩过的坑（见 docs/BUILD-NOTES.md 4.18）：
> 编译、断言、产物核验全过，开机却是 /32，路由器连不上局域网。
> 已经修了，但列在这里是因为「编译通过」和「能正常用」之间确实还隔着一步。

其他未验证项：

- **fwx 的应用识别效果** 需要真实流量才有意义，空跑看不出来
- **iStore 能否拉到应用列表** 取决于外网连通性，与固件本身无关
- **OpenClash** 内核需要联网下载，分流效果取决于你的订阅规则
- **升级路径** 从 FanchmWrt 或 iStoreOS 直接升到本固件、以及反向回去，
  都没有验证过。跨发行版升级请当作全新刷机

> `cat /etc/build-options` 那一条是特意留的：设备上直接读这个文件，
> 比回头去翻 GitHub Actions 的日志快得多。

---

## ⚠️ 授权与声明

本仓库是**整合产物**，没有修改任何上游项目的核心代码。

### FanchmWrt 的授权条款（原文保留）

FanchmWrt 的授权对**再发布**有明确要求，本项目作为其衍生固件一并遵守并在此转述：

> This project is free for personal use, you may redistribute the firmware or port
> the code to other projects, however, the copyright information in all source code
> files must be retained.
>
> The App feature file of OAF is used to describe the protocol characteristics of an
> app, individuals may use it for free, but commercial use is prohibited, you can
> extract application characteristics yourself but not directly use the open-source
> feature files, the copyright for these files belongs to FanchmWrt.

翻译过来是三件事：

1. **个人使用免费**，可以转发固件、可以把代码移植到别的项目；
2. **但必须保留所有源码文件里的版权信息**；
3. **⚠️ 应用特征库（`vendor/fanchmwrt/package/fcm/fwxd/files/feature.bin`）
   个人免费、商业使用禁止。** 你可以自己提取应用特征，但不能直接拿这份
   开源特征文件去商用 —— 版权归 FanchmWrt。

FanchmWrt 还要求：**再发布固件时请附上其仓库地址**（<https://github.com/fanchmwrt/fanchmwrt>）。

### 本仓库

- 整合部分（构建脚本、配置、补丁）以 **GPL-2.0** 发布，与 OpenWrt / ImmortalWrt 一致。
- 各上游组件（ImmortalWrt、FanchmWrt、iStoreOS、iStore、mergerfs、Docker 等）
  **版权归各自作者所有**，遵循各自的许可证。

### 特别说明

`vendor/` 目录下的代码是为了构建可复现而**原样收录**的上游代码，
版权与许可证归原作者。如果这些项目对你有帮助，请去给它们点 Star ——
尤其是 ImmortalWrt、FanchmWrt 和 iStoreOS。

### 免责声明

固件按「现状」提供，**不附带任何担保**。刷机有风险，可能变砖、可能丢数据。
请在操作前备份重要数据，并确认你知道怎么恢复。因使用本固件造成的任何损失，
作者不承担责任。

**请勿将本固件用于任何违法用途。**

---

## 📄 相关链接

| | |
|---|---|
| ImmortalWrt | <https://github.com/immortalwrt/immortalwrt> |
| FanchmWrt | <https://github.com/fanchmwrt/fanchmwrt> · <https://www.fanchmwrt.com> |
| iStoreOS | <https://github.com/istoreos/istoreos> · <https://site.istoreos.com> |
| iStore 商店 | <https://github.com/linkease/istore> |
| 构建细节与实测记录 | [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) |
