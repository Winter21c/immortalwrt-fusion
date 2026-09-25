`make target/linux/prepare` 失败 —— 内核补丁（含本项目的
`950-fwx-nf-conn-struct-user-hook.patch`）不再能干净地应用到 ImmortalWrt
的当前内核上。

## 影响

**所有人勾选 FanchmWrt 的构建都会失败。**

失败信息是 `error: 'struct nf_conn' has no member named 'fwx_data'`，
指向 fwx 自己的源码，根因却在内核侧 —— 光看报错很难定位到是补丁失效。

## 多半是什么

ImmortalWrt 换了内核版本，`struct nf_conn` 附近的代码动了，
补丁的上下文对不上。

## 怎么修

1. 看本次工作流运行的日志与摘要，确认是哪个 hunk 打不上；

2. 对照 fanchmwrt 上游 `target/linux/generic/hack-6.12/` 里的同名补丁 ——
   如果上游已经跟进了新内核，直接同步它即可：

   ```sh
   ./scripts/check-upstream.sh --apply-vendor
   ```

3. 上游若也没跟，需要人工把补丁 rebase 到新内核上。改的是
   `vendor/fanchmwrt/kernel-patches/950-fwx-nf-conn-struct-user-hook.patch`，
   涉及 4 个内核文件（`nf_conntrack.h` / `nf_fwx_user.h` /
   `nf_conntrack_core.c` / `nf_conntrack_standalone.c`）；

4. 改完验证：

   ```sh
   ./scripts/check-upstream.sh --deep     # 确认补丁能应用
   ./scripts/check-all-combos.sh          # 确认四种组合的断言仍通过
   ```

（本 Issue 由 `.github/workflows/upstream-watch.yml` 自动创建；
已存在同类 Issue 时只追加评论，不会每周开一个新的。）
