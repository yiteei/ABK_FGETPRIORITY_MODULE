# ABK_FGETPRIORITY_MODULE

ABK（AnyBase Kernel）外部模块：把 [fgetpriority](https://github.com/aerath-stuff/fgetpriority) 以**内建（`CONFIG_FGETPRIORITY=y`）**方式集成进 GKI 内核源码树，编出带 `sys_getpriority` / `sys_setpriority` / `sys_ioprio_get` / `sys_ioprio_set` 过滤的内核。

本仓库不带内核源码，只带接线：构建期从上游 `kernel/` 在线拉取 10 个文件到 `fs/fgetpriority/`，自己接线父级 `Makefile` / `Kconfig`（上游没有安装脚本），再把 `CONFIG_FGETPRIORITY=y` 写进本次构建的 defconfig。

## 用法

在 ABK 的 `custom_external_modules` 里填：

```text
https://github.com/yiteei/ABK_FGETPRIORITY_MODULE;after_patch
```

或在 ABK App 的模块列表里勾选。`module.conf` 声明支持 `after_patch` 与 `before_build`，推荐 `after_patch`；脚本不读阶段名，两阶段执行同一段幂等逻辑。

本地复现（指向 ABK 的内核工作区）：

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
bash setup.sh
```

构建机需要能访问 `raw.githubusercontent.com`，或用 `FGETPRIORITY_BASE_URL` 指向镜像。

## 产物

内核源码根在 GKI 布局下是 `$KERNEL_ROOT/common`，脚本按 `$KERNEL_ROOT/common/fs` 是否存在判定，否则用 `$KERNEL_ROOT`。

| 位置 | 改动 |
| --- | --- |
| `$KERNEL_SRC/fs/fgetpriority/` | 上游 10 个文件：`main.c` `kernel.h` `arch.h` `arm64_branch_insn.h` `routine.h` `routine_kp.c` `routine_raw.c` `Kconfig` `Makefile` `LICENSE` |
| `$KERNEL_SRC/fs/Makefile` | 追加一行 `obj-$(CONFIG_FGETPRIORITY) += fgetpriority/` |
| `$KERNEL_SRC/fs/Kconfig` | 最后一个 `endmenu` 之前插入 `source "fs/fgetpriority/Kconfig"`，没有 `endmenu` 时追加到末尾 |
| `$DEFCONFIG` | 就地改写为 `CONFIG_FGETPRIORITY=y` |

只写这四处，内核树其余部分不动。

## 执行流程

任一步失败即 `exit 1`：

1. **校验输入**：`KERNEL_ROOT` / `DEFCONFIG` 未注入则退出；`$DEFCONFIG` 文件不存在也退出，在动内核树之前发现路径拼错。
2. **定位内核源码根**，确认 `fs/` 存在。
3. **arm64 告警**：`$KERNEL_SRC/arch/arm64` 不存在时提醒，不写任何文件。
4. **`CONFIG_KALLSYMS` 检查**：依次扫 `$DEFCONFIG`、`arch/arm64/configs/gki_defconfig`、`arch/arm64/configs/defconfig`，首个命中即停，按[前置条件](#前置条件)分三态输出。
5. **判重**：十个文件齐且非空、三个内容标记对得上、两处接线都在，三者同时满足才算已集成，跳过下载。
6. **拉取并自检**：不满足就删掉目录整体重来，逐文件 `curl -fLSs --retry 3 --retry-delay 2 --connect-timeout 20`，任一文件失败或为空即删目录退出；拉完立即验三个内容标记，不符同样删目录退出。
7. **打印上游内容指纹**：十个文件拼接后的 md5。跟随 `master` 没有版本号可追溯，用指纹代替；放在接线之前，接线失败时日志里也留有拉到的是哪份源码。
8. **接线**：`fs/Makefile` 用 `grep -F` 判重后追加；`fs/Kconfig` 用 `awk` 插到最后一个 `endmenu` 之前，写临时文件再 `mv -f` 落地。
9. **复检**：把第 5 步的判重再走一遍，文件、内容、接线任一不齐即报 `integration incomplete` 退出，上游与本脚本两边的遗漏一起拦住。
10. **改写 defconfig**，按[四态规则](#defconfig-写入规则)。

第 1、2、3、4、5 步无副作用；第 6 步只动模块自己的目录；第 8、10 步是仅有的树修改。

判重把接线也算在内，所以手工删掉 `fs/Makefile` 或 `fs/Kconfig` 里的那行再重跑，脚本会补回来，不会误报“已集成”。

内容自检的三个标记，用于挡住“镜像或代理回 HTTP 200 加一个非空错误页”：

| 文件 | 必须包含 |
| --- | --- |
| `main.c` | `static int __init fgetpriority_init(void)` |
| `Kconfig` | `config FGETPRIORITY` |
| `Makefile` | `fgetpriority-y := main.o` |

## 环境变量

| 变量 | 必需 | 用途 |
| --- | --- | --- |
| `KERNEL_ROOT` | 是 | ABK 内核工作区根，用于定位 `common/` |
| `DEFCONFIG` | 是 | 本次构建的 defconfig 路径，脚本就地改写 |
| `FGETPRIORITY_BASE_URL` | 否 | 下载基地址，缺省指向上游 `master` 分支的 `kernel/` 目录；可指向镜像，镜像须保持 `<base>/<文件名>` 的扁平结构 |

`CONFIG`（内核线标识）与 `CUSTOM_EXTERNAL_MODULE_STAGE` 本脚本都不读。

## defconfig 写入规则

| `$DEFCONFIG` 当前状态 | 处理 | 日志 |
| --- | --- | --- |
| 已有 `CONFIG_FGETPRIORITY=y` | 不动 | `CONFIG_FGETPRIORITY=y already in <path>` |
| `CONFIG_FGETPRIORITY=<其它值>`（`=m`、`=n` 等） | `sed -i` 原地改成 `=y` | `rewrote CONFIG_FGETPRIORITY=y in <path>` |
| `# CONFIG_FGETPRIORITY is not set` | `sed -i` 原地改成 `=y` | `enabled CONFIG_FGETPRIORITY=y in <path>` |
| 以上都没有 | 追加 `CONFIG_FGETPRIORITY=y` | `appended CONFIG_FGETPRIORITY=y to <path>` |

`sed -i` 就地改写，不产生临时文件，属主与权限不变；重复执行结果一致。四态各一行日志，构建日志里能直接看出这次动没动 defconfig。

## 前置条件

- **`CONFIG_KALLSYMS=y`**。上游 Kconfig 是 `depends on ARM64 && KALLSYMS`，不满足时 Kconfig 会**静默丢弃** `CONFIG_FGETPRIORITY`：内核照常编出来，功能不存在，构建日志里也没有明显报错。传进来的 `$DEFCONFIG` 常是厂商 fragment，KALLSYMS 通常开在内核树默认 defconfig 里，所以脚本看三处（`$DEFCONFIG` → `gki_defconfig` → `defconfig`）：
  - 命中 `CONFIG_KALLSYMS=y`：打印命中路径，继续；
  - 命中 `# CONFIG_KALLSYMS is not set`：告警，这一行是明确关掉，不是没写；
  - 三处都没出现：另一条告警，符号可能被静默丢弃。

  只告警不代写，因为 `KALLSYMS` 也可能由别的片段或默认值开启。
- **ARM64**。上游 `main.c` 第 13 行是 `static_assert(1 == 0, "ARM64 only!")`，非 arm64 在编译期失败，脚本只给 warning。
- **内核线 5.10 ~ 6.18**（上游 DDK 矩阵覆盖 `android12-5.10` 至 `android17-6.18`），脚本不做白名单拦截。
- **构建机可访问 `raw.githubusercontent.com`**，或用 `FGETPRIORITY_BASE_URL` 指向镜像。

## 跟随上游

地址写死在脚本里，指向上游 `master` 分支：

```sh
UPSTREAM_BASE_URL="${FGETPRIORITY_BASE_URL:-https://raw.githubusercontent.com/aerath-stuff/fgetpriority/master/kernel}"
```

没有版本号可追溯，上游一提交，下一次构建就用上。上游若改结构体字段或新增 syscall 依赖，内建编译会在离本模块很远的地方失败。

要锁死就把 URL 里的 `master` 改成提交 SHA，或用 `FGETPRIORITY_BASE_URL` 指向带 SHA 的地址。每次构建打印一行十个文件拼接后的 md5，两次相同即上游源码相同：

```text
[fgetpriority] upstream content md5: <md5>
```

## 上游 `Makefile` / `Kconfig` 为什么原样保留

上游 `Makefile` 是按独立编译单元写的，下列内容原样落到内核树里，不要手改：

```make
obj-$(CONFIG_FGETPRIORITY) += fgetpriority.o
fgetpriority-y := main.o
```

- `obj-$(...)` 与 `-y` 两行在内核父 Makefile 递归进入 `fs/fgetpriority/` 时与独立编译语义一致；
- `CFLAGS_REMOVE_main.o += -Werror`：上游一批告警不至于炸掉构建；
- `-std=gnu11` → `gnu17` → `gnu23` → `gnu2y` 依次 `cc-option` 追加，后者覆盖前者：源码用了 `nullptr`、`constexpr`、`static_assert`，而 5.18 之前内核默认 `gnu89`，靠这里抬到编译器支持的最高标准；
- `-fno-stack-protector -fno-stack-check`、`CFLAGS_REMOVE_main.o += $(CC_FLAGS_FTRACE)`、`-pg`：去掉会编不过或行为异常。

上游 `Kconfig` 的 `default m` 也原样保留（那是 LKM 场景的默认值），内建由本模块在 defconfig 里覆写成 `=y`。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 集成完成，含“此前已集成、本次判重跳过” |
| `1` | 缺 `KERNEL_ROOT` / `DEFCONFIG`；`$DEFCONFIG` 不存在；无 `fs/` 目录；下载失败或下到空文件；内容自检不通过；复检报 `integration incomplete` |

curl 的退出码不单独透传，下载失败统一归到 `1`。

## 回滚

从 `custom_external_modules` 里删掉本模块即可；内核树每次构建都是全新克隆，没有持久副作用。

手工回滚已集成的树：

```sh
KERNEL_SRC=<kernel tree root>        # GKI 下即 $KERNEL_ROOT/common
rm -rf "$KERNEL_SRC/fs/fgetpriority"
sed -i '\#^obj-$(CONFIG_FGETPRIORITY) += fgetpriority/$#d' "$KERNEL_SRC/fs/Makefile"
sed -i '\#^source "fs/fgetpriority/Kconfig"$#d' "$KERNEL_SRC/fs/Kconfig"
sed -i '/^CONFIG_FGETPRIORITY=/d' "$DEFCONFIG"
```

## 排错

| 现象 | 原因与处理 |
| --- | --- |
| `KERNEL_ROOT is not set (run this through ABK)` / `DEFCONFIG is not set ...` | 未通过 ABK 运行，或手工执行缺变量 |
| `defconfig not found: <path>` | `$DEFCONFIG` 不存在，通常是变量传错或布局不同 |
| `no fs/ tree under <KERNEL_SRC>` | `KERNEL_ROOT` 不是内核树，且其下没有 `common/` |
| `warning: no arch/arm64 in <KERNEL_SRC>; fgetpriority is ARM64-only` | 目标树不是 arm64，内建编译会因 `static_assert` 失败 |
| `CONFIG_KALLSYMS=y in <path>` | 正常信息，前置条件命中 |
| `warning: CONFIG_KALLSYMS is explicitly off in <path>; Kconfig drops CONFIG_FGETPRIORITY` | 某份 defconfig 写了 `# CONFIG_KALLSYMS is not set`，符号会被丢弃。删掉那行，或换 fragment |
| `warning: CONFIG_KALLSYMS not seen in <path> or the arm64 defaults; Kconfig may drop CONFIG_FGETPRIORITY` | 三处都没写 KALLSYMS，符号可能被静默丢弃。确认该线是否另有 `select`，或换 fragment |
| `download failed: <base>` | 访问不到 `raw.githubusercontent.com`，或镜像 404。目录已被清掉，可直接重试 |
| `content check failed in <dir> (upstream changed or a mirror returned an error page)` | 代理或镜像返回了错误页，或上游改掉了内容标记。目录已被清掉；换 `FGETPRIORITY_BASE_URL` 或检查网络策略 |
| `integration incomplete: want 10 files ...` | 文件或 `fs/` 接线没落全，通常是写入失败或内核树异常 |
| 编译报 `ARM64 only!` | 目标是 arm64 之外的架构 |
| 内核编出来了但功能不在 | `CONFIG_KALLSYMS` 未开启（看构建日志里的 warning），或 `CONFIG_FGETPRIORITY` 被 Kconfig 静默丢弃 |

## 许可

`setup.sh`、`module.conf`、`README.md`、`README-EN.md` 以 **GPL-3.0-only** 发布，全文见 [`LICENSE`](LICENSE)。

本仓库不含上游 `fgetpriority` 源码，仅于构建时拉取；被集成的源码按其 **GPL-2.0-only** 许可分发，来源见 [aerath-stuff/fgetpriority](https://github.com/aerath-stuff/fgetpriority)。两者不冲突：本仓库只做下载与 `fs/` 接线，不拷贝、不修改上游代码。
