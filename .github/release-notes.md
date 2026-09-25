# ImmortalWrt 融合固件 @TAG@

以 **ImmortalWrt 25.12** 为底座，按需并入 **FanchmWrt** 与/或 **iStoreOS** 特性。
**仅支持 x86_64。**

---

## 这一版是怎么勾的

| | |
|---|---|
| **FanchmWrt 特性** | @FANCHM@ |
| **iStoreOS 特性** | @ISTORE@ |
| **Docker** | @DOCKER@ |
| **主题** | @THEME@ |
| **管理地址** | <http://@LANIP@> （`@LANIPFULL@`） |
| **rootfs 分区** | @ROOTSIZE@ MB |
| **已安装软件包** | @PKGCOUNT@ 个 |
| **底座版本** | @VERSION@ |
| **构建日期** | @DATE@（UTC） |

登录：用户 `root`，密码 `password`。**首次登录后请立刻改密码。**

---

## 镜像怎么选

| 镜像 | 什么时候用 |
|---|---|
| `…squashfs-combined-efi.img.gz` | **推荐**。UEFI 启动，squashfs 支持一键恢复出厂 |
| `…squashfs-combined.img.gz` | 传统 BIOS 启动，同样支持恢复出厂 |
| `…ext4-combined-efi.img.gz` | UEFI 启动 + ext4 根文件系统，想随意改系统文件时用 |
| `…ext4-combined.img.gz` | 传统 BIOS + ext4 |
| `sha256sums` | 校验用 |

> 近十年的机器基本都是 UEFI，选带 `efi` 的那个。拿不准就先试
> `squashfs-combined-efi`，起不来再换不带 `efi` 的。

**物理机**：解压后用 [balenaEtcher](https://etcher.balena.io/) / Rufus / `dd` 写入 U 盘或硬盘。

```sh
gunzip openwrt-x86-64-generic-squashfs-combined-efi.img.gz
sudo dd if=openwrt-x86-64-generic-squashfs-combined-efi.img of=/dev/sdX bs=4M status=progress
```

**虚拟机**：解压后的 `.img` 直接当磁盘用（Proxmox / ESXi / VirtualBox / QEMU）。

---

## 这一版里有什么

### 底座（无论怎么勾都有）

- **mosdns** —— DNS 转发 / 分流，含 geoip / geosite 规则库
- **OpenClash** —— 代理客户端。**只带界面，不含内核**：装好后进 LuCI
  打开 OpenClash，按提示下载 mihomo 内核即可（也方便你自己换版本）
- **ttyd** —— 浏览器里的 Web 终端
- **轻 NAS 套件** —— DiskMan（磁盘管理）、NFS、mergerfs（多盘合并）、
  UniShare（SMB / WebDAV 统一共享）、wsdd2（Windows 网络邻居发现）
- **明确不带** —— DDNS、硬盘休眠（hd-idle）、网络唤醒（WOL），
  以及 Samba 的**配置界面**（服务端保留，SMB 共享照常可用，只是没有网页入口）

### @FANCHM@ FanchmWrt 特性

fwx 应用识别引擎（内核态 DPI）、流量统计、行为管理、MAC 过滤、
上网记录，以及 **FanchmWrt 主题**（含仪表盘与**高级 / 普通模式**切换）。
共 17 个 `luci-app-fwx-*` 应用。

> ⚠️ **这一版改动过内核。** fwx 的内核模块要读写连接跟踪结构体
> `struct nf_conn` 里一个自定义字段 `fwx_data`，那是 FanchmWrt 自己给内核加的。
> 所以构建时打了一个内核补丁（`950-fwx-nf-conn-struct-user-hook.patch`，
> 取自 fanchmwrt 的 `target/linux/generic/hack-6.12/`）。
> 不想动内核就重新构建一次、把 FanchmWrt 那个勾去掉。

> fullcone NAT 由底座提供（ImmortalWrt 树内已有，且 `firewall4` 依赖它），
> 不在这一层里。

### @ISTORE@ iStoreOS 特性

**QuickStart 首页面板**（上网方式 / 网络状态 / Wi-Fi 一页搞定）与
**iStore 应用商店**（图形化装插件，带教程与依赖解析）。

### @DOCKER@ Docker

`dockerd` + `docker` + `docker-compose` + Dockerman 图形界面。

Docker 与 fw4 的集成**沿用 ImmortalWrt 自带实现**（它自带 `uciadd`/`ucidel`，
会创建 docker firewall zone 并自动配置好），本项目只补两件与 dockerd
版本无关、由镜像布局决定的事：squashfs 镜像上把数据目录指到
`/overlay/upper`（否则 `overlay2` 拒绝启动），以及给容器日志封顶。

---

## 关于主题与首页

规则很简单，和你勾的一致：

| 勾选 | 主题 | 首页 |
|---|---|---|
| FanchmWrt（含同时勾 iStoreOS） | FanchmWrt 主题 | FanchmWrt 仪表盘（QuickStart 排在菜单第二位） |
| 只勾 iStoreOS | argon 主题 | QuickStart |
| 都不勾 | ImmortalWrt 默认 | ImmortalWrt 默认 |

**「高级 / 普通模式」不是独立功能，它实现在 FanchmWrt 主题里** ——
所以勾了 FanchmWrt 就一定得到这套界面，这是设计如此，不是巧合。

---

## 已知边界

- **只支持 x86_64。** fwx 的内核模块、QuickStart 的后端二进制、Docker
  三者的依赖都只在 x86_64 上验证过。
- **OpenClash 不带内核**，首次使用需要联网下载。
- **fwx 的应用识别需要真实流量才有意义**，刷到真机之前无法验证效果。
- **iStore 能否拉到应用列表取决于外网连通性**，与固件本身无关。

---

## 出处与授权

本固件是整合产物，没有修改任何上游项目的核心代码。转载时请附上仓库地址。

- **底座**：[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- **FanchmWrt 特性**：[fanchmwrt/fanchmwrt](https://github.com/fanchmwrt/fanchmwrt)
  —— 依其授权条款，再发布固件时必须附上其仓库地址。
  ⚠️ 其应用特征库（`feature.bin` / `feature.cfg`）个人免费、**商业使用禁止**。
- **iStoreOS 特性**：[istoreos/istoreos](https://github.com/istoreos/istoreos)、
  [linkease](https://github.com/linkease) 系列 feed
- **构建系统**：本项目仓库（见 Release 页面顶部的仓库链接）

固件按「现状」提供，不附带任何担保。刷机有风险，请先备份数据。
