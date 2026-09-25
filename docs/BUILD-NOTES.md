# 构建记录与技术说明

这份文档记录的是**设计取舍、踩过的坑、以及实测结果**。
面向要改这个仓库的人，不是面向刷机的人（那部分看 [README](../README.md)）。

---

## 1. 这个仓库为什么不 fork 一棵完整的树

现有项目 `fanchmwrt-istoreos` 走的是另一条路：把 FanchmWrt 整棵树 fork 下来，
再把 iStoreOS 合并进去，改动直接落在树里。那份工作在那边是合适的 ——
它的目标就是「一份固定的融合固件」。

但本仓库的目标不同：**让用户自己选用不用哪个特性**。于是选型变成：

| | fork 整棵树 | 瘦构建器（本仓库） |
|---|---|---|
| 仓库体积 | ~1.5GB | ~4MB |
| 「可勾选」怎么实现 | 得在树里写条件分支 | 天然：拼不同的 `.config` |
| 上游更新 | 手工 rebase，痛 | 改一个 ref 即可 |
| 编译前能验证 | 只能真编 | `SKIP_BUILD=1` 几秒钟验配置 |

选了瘦构建器。代价是每次构建都要现拉源码与 feed（CI 上约 3~5 分钟，可忽略），
以及**必须把要改的第三方代码 vendor 进来**（见第 3 节）。

---

## 2. 构建流水线

```
build.sh
 ├─ 01-fetch.sh    取 ImmortalWrt 源码（tarball，不是 git clone）
 ├─ 02-feeds.sh    写 feeds.conf → update -a → 解除撞名 → install -a
 ├─ 03-overlay.sh  按勾选铺特性层 + 打补丁
 ├─ 04-config.sh   拼 .config → defconfig → 双向断言
 ├─ (make download && make -j)
 └─ 09-verify.sh   对照固件真实包列表核验产物
```

本地与 CI **走的是同一个 `build.sh`**，CI 只是用 `SKIP_BUILD=1` 把准备阶段
和编译阶段拆成两个 step，好让日志和重试边界清楚。这样不会出现
「本地能编、CI 编不出来」。

---

## 3. 为什么把 fanchmwrt 的代码 vendor 进来

`vendor/fanchmwrt/` 里是 fwx 内核模块、fwxd、libfwx_common、主题和 17 个
LuCI 应用的**完整源码**（约 4MB），不是构建时去上游拉的。三个理由：

1. **不受上游分支稳定性影响。** 上游 force-push、删分支、改 tag 都不会让
   这个仓库的构建在某天突然失败。
2. **内核模块可能要改。** `kmod-fwx` 原本是为 FanchmWrt 自己的内核树编译的，
   现在要编到 ImmortalWrt 的内核上。虽然两边都是 6.12、且 fwx 是标准
   netfilter 模块（源码里没有任何内核版本判断），但万一需要适配，
   代码就在手边。
3. **授权要求保留版权信息。** 原样收录是最直白的遵守方式。

同步上游用 `scripts/check-upstream.sh`（见第 7 节）。

其余三个第三方 feed（mosdns 界面、linkease 的 NAS 系列）没有 vendor ——
它们是纯 LuCI / 预编译二进制，不参与内核耦合，跟随上游反而更好。

---

## 4. 踩过的坑（按发现顺序）

### 4.1 `TOPDIR` 环境变量被 OpenWrt 劫持

**现象**：`./build.sh` 跑到 `feeds update` 就停，报

```
Unable to open feeds configuration at ./scripts/feeds line 91.
```

行号指向 `feeds` 脚本内部，而 `feeds.conf.default` 明明存在、`feeds list`
也能正常读。

**原因**：`scripts/feeds` 第 13 行是 `chdir $ENV{TOPDIR};` —— 只要环境里
有 `TOPDIR`，它就切到那里去工作。而 `build.sh` 当时正好
`export TOPDIR=<本仓库根>`，于是 feeds 跑进了本仓库根目录，
那里没有 `feeds.conf.default`。

**修法**：变量改名 `PROJECT_ROOT`，并在 `build.sh` 里注明原因。
另外 make 也有自己的 `TOPDIR`，这类名字撞车一次就够。

### 4.2 `feeds.conf` 里不能有「只有单个 `#` 的行」

**现象**：`Syntax error in feeds.conf.default, line 10`，而第 10 行是一行注释。

**原因**：`scripts/feeds` 的解析器是先 `s/#.+$//` 再判空，而 `#.+` 要求
`#` 后面**至少还有一个字符**。光秃秃一个 `#` 不会被当成注释剥掉，
会原样送进语法检查。

**修法**：`feeds.conf.append` 里禁止裸 `#` 行（写真空行或用 `# 内容`），
并在 `scripts/02-feeds.sh` 里加了一道 `sed '/^#[[:space:]]*$/d'` 兜底 ——
这个报错的行号指向注释，不给兜底的话下次还会有人踩。

### 4.3 `# CONFIG_X is not set` 后面不能跟尾注

**现象**：还没实测到，但这是 kconfig 的已知行为，先规避了。

**原因**：kconfig 按固定串匹配关闭行。写成
`# CONFIG_PACKAGE_luci-theme-argon is not set  # 说明`，
整行可能被当成普通注释忽略，符号于是取默认值 —— 结果碰巧一样，
但「显式关闭」的意图就没有了，而我们的反向断言正是靠这个。

**修法**：关闭行写得干干净净，说明另起一行。

### 4.4 主题互斥不能靠「两个都装」

**现象**：设计阶段就规避了。

**原因**：`luci-theme-fanchmwrt` 自带 `31_luci-theme-fanchmwrt` 这个
uci-defaults 去设 `luci.main.mediaurlbase`；argon 那边也有类似的脚本。
两个主题都装时，谁后跑谁赢 —— 而 uci-defaults 的执行顺序虽然按文件名
排序，却依赖两个包的安装顺序，不是我们能控制的。

**修法**：勾了 FanchmWrt 时**在配置层就不装 argon**（`grep -v` 摘掉 +
显式关闭），再加一个 `99_` 开头的 uci-defaults 把主题钉死。
这样「勾什么就得到什么」不依赖上游主题包的默认值 —— 那些默认值随时会变。

### 4.5 双主题之外：QuickStart 的首页位置

`luci-app-quickstart` 上游的菜单 `order` 就是 `1`，也就是 iStoreOS 里
「打开就进快速设置页」。同时勾两个特性时首页应该是 FanchmWrt 仪表盘，
所以把它压到 `2`；只勾 iStoreOS 时**保持上游原样不动**。

这样两边用的都是各自上游的默认行为，没有我们自己发明的东西。

### 4.6 `mosdns` 撞名

`sbwml/luci-app-mosdns` 这个 feed 同时提供二进制包 `mosdns` 和界面
`luci-app-mosdns`，而 ImmortalWrt 的 packages 源已经有一个 `net/mosdns`。
同名包只允许存在一个。

**第一次修法是错的**，值得记下来。

当时的判断是「二进制跟随底座（ImmortalWrt 的 5.3.3），界面用 sbwml 的」——
听起来很符合「能跟随底座的就跟随底座」这条原则。于是删掉了 sbwml feed 里
那份 `mosdns/`，只留界面。

`.config` 断言全过，编译也全过（两边都编得出来）。**但 `package/install`
阶段炸了：**

```
ERROR: luci-app-mosdns-1.7.14-r1: trying to overwrite
       etc/init.d/mosdns owned by mosdns-5.3.3-r1.
```

原因：sbwml 的 `luci-app-mosdns` **自带** `/etc/init.d/mosdns`，
而 ImmortalWrt 的 `mosdns` 包也装同一个文件。二进制与界面必须来自同一家。

更坑的是这个错的表现形式：`make -j` 并行时它被淹没在几千行输出里，
控制台日志的最后只有一句
`make -r world: build failed. Please re-run make with -j1 V=s`，
真正的错误要去 `-j1 V=s` 重跑一遍才看得到 —— 又是一轮几十分钟。

**最终修法**：`mosdns` 与 `luci-app-mosdns` **成对**取自 sbwml
（5.3.4 + 1.7.14，同一维护者一起维护的配套版本），底座那份 `net/mosdns`
让位。这是本仓库里**唯一一条「第三方顶掉底座」的例外**。

实现上有两个必须注意的顺序问题：

1. **删底座那份要在构造 `BASE_LIST` 之前。** 通用剪枝规则是「第三方与底座
   重名的就删第三方的」；如果底座的 `net/mosdns` 还在 `BASE_LIST` 里，
   sbwml 那份紧接着就会被剪掉，结果两边都没了。
2. **必须重建 `packages` feed 的索引。** `feeds install` 照索引装，
   不现扫目录；漏了这一步，底座的 mosdns 会照旧索引被装回来，
   撞文件问题原样复现。

这条教训是：**「跟随底座」是默认策略，不是教条。** 当第三方包与底座包在
**文件层面**耦合（同一个 init 脚本、同一份配置）时，混搭就是错的 ——
而这种错在配置与编译阶段都看不出来。

顺带砍掉了三个原本计划要用的第三方 feed：

| 原计划 | 为什么砍掉 |
|---|---|
| `jjm2473/openwrt-third` | 与 ImmortalWrt 自带的 luci-theme-argon / luci-app-argon-config / luci-app-nfs **全部重名** |
| `vernesong/OpenClash` | ImmortalWrt 的 luci 源**自带** luci-app-openclash |
| `lisaac/luci-app-diskman` | ImmortalWrt 的 luci 源**自带** luci-app-diskman |

少三个 feed，就少三处会腐烂的外部依赖。

### 4.7 `s#.+$//` 之外：`head` 引发的 SIGPIPE 噪音

`curl ... | sed ... | head -1` 里 `head` 提前关闭管道会让 sed 收到 SIGPIPE，
日志里留下一行 `couldn't flush stdout: 断开的管道`。看着像出错，其实不是。
改成 `sed -n '1s/.../\1/p'`，就不需要 `head`。

### 4.8 `set -e` 下的 `A && B` 结尾

`grep -q X && die ...` 或 `[ cond ] && say ...` 作为代码块的**最后一句**时，
条件不成立会让整块返回非零，`set -e` 直接把脚本带走 —— 而这恰恰是
「一切正常」的分支。

**修法**：这几处统一加 `|| true`。踩到的位置：
`01-fetch.sh` 的 SHA 记录、`04-config.sh` 的镜像开关检查、
`09-verify.sh` 的校验和汇总。

### 4.9 砍掉 dockerd 补丁：别为了「和某个发行版一致」替换能工作的实现

**现象**：从现有项目继承来的 `patches/0001-dockerd-istoreos.patch`
（**本仓库里已经没有这个文件了**，下面说的就是为什么删掉它）
在 ImmortalWrt 的 dockerd 上既不匹配正向也不匹配反向。

**排查**：先对比两边，再读代码。结论比「补丁打不上」重要得多：

| | ImmortalWrt 自带的 dockerd | iStoreOS 的定制 |
|---|---|---|
| 版本 | 29.6.1 | 27.3.1 |
| iptables | `iptables='1'`，docker 自己管 | 关掉，全部搬到 fw4 |
| firewall zone | `dockerd.init` 的 `uciadd` 自动创建，postinst 调用 | 靠 uci-defaults `17_docker-fw4` |
| 出网 NAT | docker 自己的规则 | 额外补 `172.16.0.0/12` 的 MASQUERADE |

**两边的做法是相反的。** 把 iStoreOS 那套套上来，等于把 ImmortalWrt 一套
本来就能工作的机制拆掉换成另一套 —— 收益不明，风险很实在。

**修法**：不打任何 dockerd 补丁。只保留两件与 dockerd 版本无关、
纯粹由「x86 + 镜像布局」决定的事，放进独立的小包
`vendor/istoreos/package/docker-defaults`：

1. squashfs 镜像上把 `data_root` 指到 `/overlay/upper`
   （ImmortalWrt 默认的 `/opt/docker/` 在 overlay 上，overlay2 会拒绝启动）；
2. `log_driver='local'` 给容器日志封顶（上游默认 json-file 不轮转）。

**教训**：这里差点犯的错是「因为那边这么做，所以这边也这么做」。
真正该问的问题是「底座自己怎么做的，够不够用」。

### 4.10 补丁的 `-d` 目录层级：`-p1` 之后还剩什么

**现象**：`0002-quickstart-menu-order.patch` 报「既不匹配正向也不匹配反向」，
看起来像上游改了文件，实际文件内容与补丁上下文**一字不差**。

**原因**：`-d` 给多了一层。补丁里的路径是
`a/luci/luci-app-quickstart/root/usr/share/luci/menu.d/...`，`-p1` 剥掉 `a/`
之后剩下 `luci/luci-app-quickstart/...`，所以 `-d` 要给 **feed 根目录**
（`feeds/nas_luci`）。当时给的是 `feeds/nas_luci/luci`，路径就变成了
`feeds/nas_luci/luci/luci/luci-app-quickstart/...`。

**判断方法**：`patch` 的报错完全一样（正向反向都不匹配），
分不清是「层级错」还是「内容变了」。最快的区分方式是直接看目标文件在不在
预期位置，再单独 `patch --dry-run -d <目录>` 试一次。

### 4.11 会在上游改文件时失效的补丁，等于给未来埋雷

**现象**：`0003-v2ray-geodata-rolling-releases.patch`（从现有项目继承）
打不上 —— ImmortalWrt 更新了 pin 的版本号和 HASH，补丁上下文对不上。

**背景**：这个包提供 geoip / geosite 规则数据，`luci-app-mosdns` 的
`LUCI_DEPENDS` 里有 `+v2ray-geoip +v2ray-geosite`，**所以不能删**。
而它的数据源是「滚动发布 + 定期删旧 tag」：
`v2fly/domain-list-community` 只保留约三个月。feed 里 pin 死的版本到点就 404，
构建直接失败，而失败现象是「编译不过」、原因却是「一个规则数据包没了」。

**修法**：不再用 `.patch`，改成**带校验的重写**（`scripts/03-overlay.sh`）：

- 重写用 `sed`，只认「结构」不认「具体版本号」，上游更新版本号不影响它；
- 重写完**逐项校验结果**：3 个 `releases/latest/download/`、3 个 `HASH:=skip`、
  3 个 `*_VER:=1`、且不残留 `releases/download/$(...)/`。任一项不符就报错中止，
  并把实测内容打出来。

这样上游的修饰性改动不会让构建失败，而结构性重构会**明确**失败而不是
静默产出一个看起来正常、实际下错数据的 Makefile。

两个细节：
- 版本号固定为 `1` 而不是 `latest` —— apk 只接受数字开头的版本号。
- `HASH:=skip` 意味着这三个数据文件不再校验哈希（内容随上游滚动）。
  它们只是 DNS 分流规则数据，不参与编译，也不影响其它包。

### 4.12 fwx 需要一处内核改动：`struct nf_conn` 加字段

**现象**：`make` 编到 `package/fcm/fwx` 时失败：

```
error: 'struct nf_conn' has no member named 'fwx_data'
```

**排查**：报错指向 `fwx_main.c` 的几十处 `ct->fwx_data`，但 `struct nf_conn`
是**内核**里的连接跟踪结构体，不在 fwx 的源码里。说明 FanchmWrt 改过内核。

在 fanchmwrt 树里找到了那处改动：

```
fanchmwrt/target/linux/generic/hack-6.12/950-fwx-nf-conn-struct-user-hook.patch
```

对比整个 `hack-6.12` 目录，这是 fanchmwrt **唯一**区别于上游的内核补丁。
它改 4 个文件：

| 文件 | 改什么 |
|---|---|
| `include/net/netfilter/nf_conntrack.h` | 定义 `struct nf_fwx_data`，并作为成员加进 `struct nf_conn` |
| `include/net/netfilter/nf_fwx_user.h` | 新文件，给内核侧用的 ops 结构 |
| `net/netfilter/nf_conntrack_core.c` | conntrack 初始化时把字段清零 |
| `net/netfilter/nf_conntrack_standalone.c` | /proc 输出里带上 fwx 信息 |

**修法**：把这个补丁 vendor 进
`vendor/fanchmwrt/kernel-patches/`，在 `scripts/03-overlay.sh` 里
**勾选 FanchmWrt 时装上、不勾时卸下**。

实测它能干净地落到 ImmortalWrt 的 6.12.108 上：4 个文件、10 个 hunk，
其中两个 hunk 偏移 43 行，`patch` 自动处理，无失败。

编号选 950 是因为 ImmortalWrt 的 `hack-6.12/` 里 950 是空的，且上游自己也把
它编号在系列末尾。放在 `hack-` 而不是 `x86/patches-` 下，是因为
`hack-*` 对所有目标生效 —— 虽然本项目只出 x86，但与上游的分类保持一致。

**这条是本项目对底座的唯一实质性改动。** 其余全是叠加（加包、加主题、
加 feed）。所以 README 里必须显著声明：不想动内核就不要勾 FanchmWrt。

#### 附带加的一道保险

先说清楚：**OpenWrt 本来就会处理这件事。** `include/kernel-build.mk` 的
`KERNEL_FILE_DEPENDS` 里包含 `GENERIC_HACK_DIR`，也就是整个补丁目录都是
内核 prepare 的依赖 —— 目录里增删文件会改变目录的 mtime，从而自动触发重新
prepare。（这一条是核对 makefile 确认的，不是推测。）

之所以还是加了一道显式的保险：这个失败模式太难查。一旦内核与勾选不符，
现象是 fwx 编不过、或者运行时起不来，而报错全部指向 fwx 自己，指不到内核。

做法是给补丁状态留一个指纹（`.generated/kernel-fwx-patch`），变了就
`make target/linux/clean`。代价是内核重编一次（十几分钟），换一个
「所见即所得」的确定性。

### 4.13 构建独占锁：两个构建不能共用一个工作区

不是「踩坑」，是预判。两个 `build.sh` 共用一个 `openwrt/` 树时，
`.config`、`package/`、`tmp/`、`dl/` 全是共享的，交叉写入产出的错误极难解释 ——
典型现象是「参数明明选了不含 Docker，编出来的固件里却有 Docker」，
因为另一个进程把 `tmp/` 里的元数据换了。

用 `mkdir` 实现（POSIX 上原子），锁目录里留 pid，被占用时报错会指名占锁进程。
已单独验证：获取成功、退出自动释放、被占用时明确失败。

### 4.14 `patch` 报错信息为什么容易误导

上面 4.10 和 4.11 都是 `patch` 失败，而报错文本一模一样。三次踩坑分别来自
「环境变量被劫持」「目录层级给错」「上游真的改了文件」。

所以 `scripts/03-overlay.sh` 里 `apply_patch` 的报错文案特意写全了可能的
方向，而不是只说「补丁打不上」。排查顺序建议：

1. 目标文件在不在预期位置？（`-d` 层级）
2. 单独 `patch --dry-run` 一次，看是 hunk 失败还是文件找不到；
3. 目标文件内容与补丁上下文比一比，确认是不是上游真的改了。

### 4.16 上游有 7 个 Makefile 是 CRLF，导致包被静默丢弃

**现象**：把 FanchmWrt 层的包清单从「写死」改成「从 `vendor/` 枚举」之后，
17 个应用里有 7 个在 `make defconfig` 之后变成 `is not set`，断言报
「该有却没有」。

**排查**：`less` 看不出任何异常，包名就是 `luci-app-fwx-app-center`。
直到 `od -c` 打出来才发现：

```
C O N F I G _ P A C K A G E _ l u c i - a p p - f w x - a p p - c e n t e r \r = y
```

包名里有一个**回车**。上游有 7 个 `luci-app-fwx-*` 的 Makefile 是 CRLF 行尾，
`PKG_NAME:=xxx\r\n`，我的 `sed` 取出 `xxx\r`，`tr -d ' \t'` 又没删掉它。

kconfig 认不出带 `\r` 的符号名，**静默丢弃** —— 不报错，只是那个包没了。

**修法**：`tr -d ' \t\r\n'`，并加一道格式哨兵：包名里出现
`[A-Za-z0-9._+-]` 之外的字符就直接报错中止。

**值得记的是它怎么被发现的**：断言把「该有却没有」报了出来。
如果没有那道反向断言，这会是一个「构建全绿、固件里少了 7 个应用」的结果 ——
而这种错用户要刷完机才会发现。

顺带说明：**没有去规整 vendor 里的 CRLF**。构建系统自己能处理
（kconfig 符号名走的是 metadata dump，那里 strip 干净了），规整反而会让
vendor 与上游产生无谓的差异，以后每次 diff 都对不上。

### 4.17 `PROJECT_ROOT` 只在经过 build.sh 时才存在

**现象**：CI 上全量编译**成功**（130 分钟），随后的「核验产物」步骤却挂了：

```
./scripts/09-verify.sh: 15: PROJECT_ROOT: parameter not set
```

**原因**：这几个脚本一直靠 `build.sh` 里那句 `export PROJECT_ROOT` 拿到项目根。
本地与 CI 的 `build.sh` 路径都没问题 —— 但 CI 的工作流把核验**拆成了一个
独立 step**（为了日志与重试边界更清楚），直接调 `./scripts/09-verify.sh`，
那时没有任何人导出过这个变量。

**修法**：`scripts/0*.sh` 全部自己推导项目根，不再依赖调用方：

```sh
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
. "$PROJECT_ROOT/scripts/lib.sh"
```

同一个坑在 `check-all-combos.sh` 上先踩过一次（它是被工作流直接调的）。
当时只修了那一个，没有意识到「凡是被独立调用的脚本都要自推导」——
**修一个点，要顺手问一句「还有谁在同样的处境」**。

#### 顺带暴露的第二个问题：期望清单会过期

本地复现时发现另一件事：先 `build.sh` 编了组合 ①，之后跑
`check-all-combos.sh` 会把 `.generated/expectations.env` 覆盖成**最后一个
组合**的，而产物还是原来那份。再跑核验就会拿错清单去比对，报出一长串
「不该有却有」，看起来像构建错了。

现在加了一道**单向**的过期判定：只看「标志为关、产物里却有对应的代表包」，
两个以上才提示。方向刻意做成单向的 —— 反过来（标志为开、产物里却没有）
仍然是真正的失败，照常报错，不能因为怀疑清单过期就放过真问题。

### 4.18 管理地址丢了前缀长度，LAN 变成 /32（只有真启动才发现）

**现象**：在 QEMU 里启动固件后，`ip -4 addr show br-lan` 出来的是

```
inet 192.168.1.1/32 brd 255.255.255.255 scope global br-lan
```

而且 `ip route` 里**只有 docker0 那一条**，没有 `192.168.1.0/24`。

**后果**：路由器连不上局域网里的任何设备，LuCI 打不开 —— 而配置里明明写着
`192.168.1.1`，界面上看不出任何异常。

**根因**：OpenWrt 的 `config_generate` 生成 lan 时写的是

```
add_list network.lan.ipaddr='192.168.1.1/24'
```

—— **前缀长度写在 `ipaddr` 里，没有单独的 `netmask` 选项**
（`package/base-files/files/bin/config_generate` 第 170-177 行）。

而我们的 `25_lan_ip` uci-defaults 为了改地址必须 `delete` 再 `add_list`
（config_generate 把它生成成了 list，不 delete 会同时留下两个地址）。
这时只写 `192.168.1.1`，前缀就丢了。

**修法**：`scripts/04-config.sh` 里统一补全 —— 没写前缀就补 `/24`
（OpenWrt 的默认值），显式写了就原样尊重。

**这个 bug 的价值在于它躲过了前面所有关卡**：

| 关卡 | 为什么没抓到 |
|---|---|
| 编译 | 语法与依赖都没问题 |
| `.config` 双向断言 | 断言的是「装没装这个包」，不检查包内配置文件的语义 |
| `09-verify.sh` | 对照的是包清单与镜像校验和 |
| 离线翻镜像 | 打开 `25_lan_ip` 看，脚本本身完全正常 —— 缺的是对它**运行结果**的理解 |

**只有真启动一次才会暴露。** 这也是为什么 README 里那段「刷机后先确认这几件事」
不是客套话 —— 编译通过、断言全过、产物核验通过，仍然可能开机就连不上。

### 4.15 第三方 feed 剪枝：让位给底座

**现象**：`luci-app-cpufreq` 在三个地方同时存在 ——
`feeds/luci/applications/`（ImmortalWrt 自带）、`package/emortal/cpufreq`
（树内）、`feeds/istoreapps/`（linkease）。同名包只允许存在一个。

**修法**：`scripts/02-feeds.sh` 里写了一条通用规则 ——
收集底座（ImmortalWrt 自带的 5 个 feed + 树内 `package/`）里所有**真正定义包**
的目录名，凡是第三方 feed 里同名的就删掉。这样上游哪天新增重名包也是自动
让位，而不是在 defconfig 阶段以很难懂的形式炸掉。

两个实现细节值得记：

- **只把「真正定义包」的目录当包目录。** 判据是 Makefile 里有
  `BuildPackage` / `KernelPackage` / `define Package/`。
  否则 `luci-lib-mac-vendor/src/Makefile` 这类编译单元会被误剪，把包弄坏。
  （干跑时正是它暴露了这个问题。）
- **剪完必须重建索引。** `feeds install` 是照 `feeds/<name>.index` 装的，
  不是现扫目录。索引还是剪枝前那一份，install 就会去装已经被删掉的路径，
  报错指向一个根本不存在的目录。用 `./scripts/feeds update -i <feeds>`
  只重建索引、不拉 git。另外上一轮 install 留下的断链也要清掉。

---

## 5. 实测记录

> 这一节的内容必须来自真实运行，不许写「应该没问题」。

### 5.1 四种组合的配置断言

命令：`./scripts/check-all-combos.sh`（等价于四次 `SKIP_BUILD=1 ./build.sh`）。
**本地与 GitHub Actions 上各跑过一次，结果一致。**

| 组合 | 必须在位 | 确认排除 | 主题 | 本地 | CI |
|---|---:|---:|---|---|---|
| ① FanchmWrt + iStoreOS + Docker | 56 | 7 | FanchmWrt | ✅ | ✅ |
| ② 只要 FanchmWrt | 42 | 23 | FanchmWrt | ✅ | ✅ |
| ③ 只要 iStoreOS | 36 | 26 | Argon | ✅ | ✅ |
| ④ 都不勾（纯底座） | 21 | 42 | 不锁（ImmortalWrt 默认） | ✅ | ✅ |

其他实测到的点：

| 项目 | 结果 |
|---|---|
| 拉取 ImmortalWrt | 12.4MB tarball，解开后约 1.5GB |
| feed 数量 | 10 个（底座 5 + 追加 5） |
| 第三方 feed 剪枝 | 剪掉 `mosdns`（撞底座 net/mosdns）与 `luci-app-cpufreq`（撞三处）；全新克隆路径同样生效 |
| vendored 包重名拦截 | 拦下 `fullconenat` / `fullconenat-nft` —— 与 ImmortalWrt 树内同名，且 `fullconenat-nft` 逐字节相同 |
| `v2ray-geodata` 滚动地址重写 | 3 个数据源全部改写并逐项校验通过 |
| QuickStart 菜单序号 | 同时勾两个特性时压到 2；只勾 iStoreOS 时保持上游的 1 |
| 配置回归检查耗时 | 约 10 分钟（含一次完整 feeds update + 四次 defconfig），CI 实测 |

**断言抓到的真实错误**（如果只断言「该有的在」，这两个都会漏过去）：

1. `v2ray-geodata` 写成了包名 —— 它其实是**源包名**，实际产物是
   `v2ray-geoip` / `v2ray-geosite`。断言报「该有却没有」。
2. `kmod-nft-fullcone` 与 `luci-compat` 被误当成 FanchmWrt 层的东西 ——
   实际上前者是 `firewall4` 的依赖、后者是底座层几个 LuCI 应用的依赖，
   任何组合下都在。断言报「不该有却有」。

### 5.2 完整编译

组合：FanchmWrt + iStoreOS + Docker，LAN 192.168.1.1，rootfs 1024MB。
本机 12 核（i7-1355U）/ 31GB。

**前两次编译都是失败的**，而且失败得有价值 —— 它们暴露了两个只看代码
绝对发现不了的问题（详见 4.12 与 4.6）。第三次通过。

| 项目 | 结果 |
|---|---|
| 编译结果 | ✅ 通过，零错误 |
| `scripts/09-verify.sh` | ✅ 产物核验全部通过 |
| 镜像 | 4 个，与设计一致：squashfs-combined-efi / squashfs-combined / ext4-combined-efi / ext4-combined |
| 镜像大小 | squashfs 各 125MB，ext4 各 157MB |
| sha256sums | 全部校验通过 |
| 固件内软件包 | 513 个 |
| 本次耗时 | 约 26 分钟 —— 但这是**增量重编**（build_dir 里已有前两次的产物），不是冷编译，不能当参考值 |

**从固件里读出来的真实版本**（不是 `.config` 里写了什么，是固件里到底装了什么）：

| 包 | 版本 |
|---|---|
| `kmod-fwx` | `6.12.108-r1` ← **DPI 内核模块确实编到了 ImmortalWrt 的 6.12.108 内核上** |
| `fwxd` | `1.0.4-r1` |
| `mosdns` | `5.3.4-r14` ← 与界面同源（sbwml 配套版本） |
| `luci-app-mosdns` | `1.7.14-r1` |
| `luci-theme-fanchmwrt` | 在固件里 |
| `luci-app-quickstart` | `0.12.10-r1` |
| `luci-app-store` | `0.2.1-r1` |
| `dockerd` | `29.6.1-r1` |
| `luci-app-openclash` | `0.47.156` |
| `luci-app-ttyd` | `26.249.28459~d6167ea` |
| `build-defaults` | 在固件里（承载管理地址与主题锁定） |

**反向核对**（这些是明确不要的，逐个确认确实不在固件里）：

```
luci-app-ddns      ✅ 不在
luci-app-hd-idle   ✅ 不在
luci-app-wol       ✅ 不在
luci-app-samba4    ✅ 不在
luci-theme-argon   ✅ 不在（勾了 FanchmWrt，主题让位）
```

`kmod-fwx` 的 `.ko` 落点是 `lib/modules/6.12.108/fwx.ko`，870KB —
与固件里 `kmod-fwx 6.12.108-r1` 的版本号对得上。

### 5.3 冷编译耗时

（待填：CI 上全新克隆的实测耗时 —— 那才是用户实际会遇到的时间）

### 5.4 上游跟进检查

`upstream-watch.yml` 在 GitHub Actions 上**手动触发实测通过**（全新克隆环境）：

| 步骤 | 结果 |
|---|---|
| 准备源码树（`SKIP_BUILD=1 ./build.sh`） | ✅ |
| 检查上游（`check-upstream.sh --deep`） | ✅ 退出码 0 |
| 写进运行摘要 | ✅ |
| 把 vendor 更新推成 PR | ⏭️ 正确跳过（无变化） |
| 内核补丁失效时开 Issue | ⏭️ 正确跳过（无变化） |

报告里关键的两行：

```
## ✅ FanchmWrt vendor 与上游一致

## 内核补丁兼容性
✅ 能应用
`make target/linux/prepare` 成功，内核 + 全部补丁（含 950-fwx）都打上了。
```

**「能应用」这一条是重点**：它说明 `--deep` 真的跑了 `make target/linux/prepare`，
不是因为没有源码树而被跳过。这恰好是本项目最脆弱的一环 —— 内核补丁一旦打不上，
所有人勾 FanchmWrt 的构建都会失败，而报错指向 fwx 源码、根因在内核侧。

`check-all-combos.sh` 也在本地与 CI 上各跑通过一次（本地约 10 分钟，CI 上 6m22s）。

### 5.5 QEMU 实机验证（做了）

第一次真启动。用的是编出来的 `squashfs-combined` 镜像，QEMU/KVM + virtio
磁盘与网卡，串口控制台驱动。

**结论：启动正常，界面能打开，而且抓到一个只有真启动才能发现的 bug（第 4.18 节）。**

| 验证项 | 结果 |
|---|---|
| 引导 | ✅ GRUB → Linux **6.12.108**，KVM 加速 |
| 根文件系统 | ✅ `/dev/vda2` squashfs(ro) on `/rom` + f2fs on `/overlay` + overlayfs on `/` |
| **fwx 内核模块** | ✅ `dmesg`: `fwx: Driver ver. 1.0.4 - Copyright(c) 2026, fanchmwrt`、`fwx: init ok`；`lsmod`: fwx 110592 |
| fwxd 守护进程 | ✅ `/usr/bin/fwxd` 运行中 |
| uhttpd | ✅ 运行中 |
| 主题 | ✅ `luci.main.mediaurlbase = /luci-static/fanchmwrt`；`/www/luci-static/` 里有 `fanchmwrt`，**没有 argon** |
| 管理地址 | ✅ `192.168.1.1/24`，`br-lan` 上掩码正确 |
| 局域网路由 | ✅ `192.168.1.0/24 dev br-lan proto kernel scope link src 192.168.1.1` |
| **LuCI 可访问** | ✅ 主机侧 `curl http://127.0.0.1:8080/` 返回 **HTTP 200** |
| Docker | ✅ `running`，`Server Version: 29.6.1`，`Storage Driver: overlayfs`，`Containers: 0` |
| 磁盘占用 | ✅ overlayfs 904.8M，已用 68.8M（8%） |
| `/etc/build-options` | ✅ 在固件里，参数与构建时一致 |
| FanchmWrt 模式默认值 | ✅ `100_fwx` 设了 `fwx.global.theme_mode=\'1\'` |

**第一次启动（修复前）是失败的**：`br-lan` 拿到 `192.168.1.1/32`，`ip route`
里只有 docker0 一条 —— 路由器连不上局域网，LuCI 打不开。修完前缀长度之后
重编、重启，掩码与路由都正确，LuCI 返回 200。详见第 4.18 节。

**仍然没有验证的**（需要真机 + 真实环境）：

- 真实网卡（QEMU 里是 virtio，真机上是各种物理网卡驱动）
- **fwx 的应用识别效果** —— 需要真实流量，空跑看不出来
- WAN 口上网、PPPoE、IPv6
- iStore 能否拉到应用列表（取决于外网连通性）
- OpenClash 内核下载与分流（取决于订阅规则）
- 从 FanchmWrt / iStoreOS 升级过来的路径
