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

同步上游用 `scripts/sync-vendor.sh`（如果上游改了 fwx，重跑它并 review diff）。

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

**修法**：`scripts/02-feeds.sh` 在 `feeds update` 之后删掉 feed 里那份
`mosdns/`，二进制用 ImmortalWrt 自带的（5.3.3，跟着底座走），
界面用 sbwml 的（ImmortalWrt 没有 mosdns 的 LuCI 应用）。

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

**现象**：`patches/0001-dockerd-istoreos.patch`（从现有项目继承来的）
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

### 4.11 补丁的 `-d` 目录层级：`-p1` 之后还剩什么

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

### 4.12 会在上游改文件时失效的补丁，等于给未来埋雷

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

### 4.13 `patch` 报错信息为什么容易误导

上面 4.11 和 4.12 都是 `patch` 失败，而报错文本一模一样。三次踩坑分别来自
「环境变量被劫持」「目录层级给错」「上游真的改了文件」。

所以 `scripts/03-overlay.sh` 里 `apply_patch` 的报错文案特意写全了可能的
方向，而不是只说「补丁打不上」。排查顺序建议：

1. 目标文件在不在预期位置？（`-d` 层级）
2. 单独 `patch --dry-run` 一次，看是 hunk 失败还是文件找不到；
3. 目标文件内容与补丁上下文比一比，确认是不是上游真的改了。

### 4.10 第三方 feed 剪枝：让位给底座

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

### 5.1 准备阶段（`SKIP_BUILD=1 ./build.sh`）

| 项目 | 结果 |
|---|---|
| 四组合一（FanchmWrt + iStoreOS + Docker） | 见下 |
| 拉取 ImmortalWrt | 12.4MB tarball |
| feed 数量 | 10 个 |

（待填：四组合各自的断言结果）

### 5.2 完整编译

（待填：首次真编的耗时、产物大小、核验结果）

### 5.3 QEMU 实机验证

（待填：如果做了的话）

---

## 6. 还没验证的

诚实列出来，别让使用者以为都验过了：

- **四种组合里只实编了哪些**：见 5.2。另外三种组合的 `.config` 断言是过的，
  但没有真编过 —— 差别主要在包集合，编不过的风险低，但不是零。
- **fwx 的应用识别效果**：需要真实流量，空跑看不出来。
- **iStore 能否拉到应用列表**：取决于外网连通性。
- **OpenClash**：内核要联网下载，分流效果取决于订阅规则。
- **升级路径**：从 FanchmWrt 或 iStoreOS 直接升到本固件、以及反向回去，
  都没有验证过。跨发行版升级请当作全新刷机。
