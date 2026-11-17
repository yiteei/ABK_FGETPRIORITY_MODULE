# ABK_FGETPRIORITY_MODULE

An ABK (AnyBase Kernel) external module that integrates [fgetpriority](https://github.com/aerath-stuff/fgetpriority) into a GKI kernel tree as a **built-in** (`CONFIG_FGETPRIORITY=y`), producing a kernel with filtering on `sys_getpriority` / `sys_setpriority` / `sys_ioprio_get` / `sys_ioprio_set`.

This repository carries no kernel source and only wires things up: at build time it downloads the ten files of the upstream `kernel/` directory into `fs/fgetpriority/`, wires the parent `Makefile` / `Kconfig` itself (upstream has no install script), and writes `CONFIG_FGETPRIORITY=y` into the defconfig of the current build.

## Usage

Put this into ABK's `custom_external_modules`:

```text
https://github.com/yiteei/ABK_FGETPRIORITY_MODULE;after_patch
```

or tick it in the ABK app's module list. `module.conf` declares support for `after_patch` and `before_build`, recommending `after_patch`; the script never reads the stage name and runs the same idempotent logic in either stage.

To reproduce locally against an ABK kernel workspace:

```sh
KERNEL_ROOT=/path/to/abk/kernel \
DEFCONFIG=/path/to/kernel/common/arch/arm64/configs/gki_defconfig \
bash setup.sh
```

The build machine must reach `raw.githubusercontent.com`, or `FGETPRIORITY_BASE_URL` must point at a mirror.

## What it writes

Under the GKI layout the kernel source root is `$KERNEL_ROOT/common`; the script picks it when `$KERNEL_ROOT/common/fs` exists and falls back to `$KERNEL_ROOT` otherwise.

| Location | Change |
| --- | --- |
| `$KERNEL_SRC/fs/fgetpriority/` | The ten upstream files: `main.c` `kernel.h` `arch.h` `arm64_branch_patch.h` `routine.h` `routine_kp.c` `routine_raw.c` `Kconfig` `Makefile` `LICENSE` |
| `$KERNEL_SRC/fs/Makefile` | Appends one line, `obj-$(CONFIG_FGETPRIORITY) += fgetpriority/` |
| `$KERNEL_SRC/fs/Kconfig` | Inserts `source "fs/fgetpriority/Kconfig"` before the last `endmenu`, appending at the end when there is none |
| `$DEFCONFIG` | Rewritten in place to `CONFIG_FGETPRIORITY=y` |

Those four places are all it touches.

## Flow

Any failing step exits `1`:

1. **Check inputs**: `KERNEL_ROOT` / `DEFCONFIG` missing exits, and so does a missing `$DEFCONFIG` file, catching a mistyped path before the tree is touched.
2. **Resolve the kernel source root** and confirm `fs/` exists.
3. **Warn about arm64**: a missing `$KERNEL_SRC/arch/arm64` produces a warning and no writes.
4. **Check `CONFIG_KALLSYMS`**: scans `$DEFCONFIG`, then `arch/arm64/configs/gki_defconfig`, then `arch/arm64/configs/defconfig`, stopping at the first hit and reporting one of three states as described under [Prerequisites](#prerequisites).
5. **De-duplicate**: ten files present and non-empty, the three content markers matching, and both wiring lines in place together mark the module as integrated and skip the download.
6. **Fetch and self-check**: anything missing removes the directory for a full refetch, then per file `curl -fLSs --retry 3 --retry-delay 2 --connect-timeout 20`; any failure or empty file removes the directory and exits, and the three content markers are verified right after the fetch, with the same removal on a mismatch.
7. **Print the upstream content fingerprint**: the md5 of the ten files concatenated. `master` carries no version to trace, so the fingerprint stands in, and it prints before wiring so the log still records which source was fetched when wiring later fails.
8. **Wire**: `fs/Makefile` gets the line appended after a `grep -F` guard; `fs/Kconfig` gets it inserted before the last `endmenu` by `awk`, written to a temporary file and moved into place with `mv -f`.
9. **Re-check**: runs step 5's test again and exits with `integration incomplete` if files, content, or wiring are missing, catching omissions from both upstream and this script.
10. **Rewrite the defconfig** per the [four-state rule](#defconfig-write-rule).

Steps 1, 2, 3, 4, and 5 have no side effects; step 6 touches only this module's own directory; steps 8 and 10 are the only tree edits.

De-duplication counts the wiring, so deleting either wired line by hand and re-running gets it restored instead of a false "already integrated".

The three content markers exist to catch a mirror or proxy answering HTTP 200 with a non-empty error page:

| File | Must contain |
| --- | --- |
| `main.c` | `static int __init fgetpriority_init(void)` |
| `Kconfig` | `config FGETPRIORITY` |
| `Makefile` | `fgetpriority-y := main.o` |

## Environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `KERNEL_ROOT` | yes | ABK kernel workspace root, used to locate `common/` |
| `DEFCONFIG` | yes | defconfig of the current build, rewritten in place |
| `FGETPRIORITY_BASE_URL` | no | Download base URL, defaulting to the `kernel/` directory on upstream `master`; a mirror must keep the flat `<base>/<file>` layout |

The script reads neither `CONFIG` (kernel line) nor `CUSTOM_EXTERNAL_MODULE_STAGE`.

## defconfig write rule

| Current state of `$DEFCONFIG` | Action | Log line |
| --- | --- | --- |
| Already says `CONFIG_FGETPRIORITY=y` | untouched | `CONFIG_FGETPRIORITY=y already in <path>` |
| Says `CONFIG_FGETPRIORITY=<something else>` (`=m`, `=n`, ...) | `sed -i` rewrites it to `=y` | `rewrote CONFIG_FGETPRIORITY=y in <path>` |
| Says `# CONFIG_FGETPRIORITY is not set` | `sed -i` rewrites it to `=y` | `enabled CONFIG_FGETPRIORITY=y in <path>` |
| Says none of the above | appends `CONFIG_FGETPRIORITY=y` | `appended CONFIG_FGETPRIORITY=y to <path>` |

`sed -i` edits in place: no temporary file, ownership and permissions unchanged, and repeated runs converge. Each of the four states has its own log line, so the build log shows whether the defconfig was touched.

## Prerequisites

- **`CONFIG_KALLSYMS=y`**. The upstream Kconfig says `depends on ARM64 && KALLSYMS`, and Kconfig **silently drops** `CONFIG_FGETPRIORITY` when that is unmet: the kernel builds, the feature is absent, and the build log shows nothing obvious. The incoming `$DEFCONFIG` is often a vendor fragment while KALLSYMS lives in the kernel tree's default defconfigs, so the script reads three files (`$DEFCONFIG`, then `gki_defconfig`, then `defconfig`):
  - A `CONFIG_KALLSYMS=y` hit prints the path and continues.
  - A `# CONFIG_KALLSYMS is not set` hit warns that the symbol is deliberately off rather than merely absent.
  - A total miss warns separately that the symbol may be dropped silently.

  It warns instead of writing the symbol because `KALLSYMS` can also arrive from another fragment or a default value.
- **ARM64**. Line 13 of the upstream `main.c` is `static_assert(1 == 0, "ARM64 only!")`, so a non-arm64 target fails at compile time; the script only warns.
- **Kernel lines 5.10 to 6.18** (the upstream DDK matrix covers `android12-5.10` through `android17-6.18`), with no allow-list enforced here.
- **`raw.githubusercontent.com` reachable from the build machine**, or `FGETPRIORITY_BASE_URL` pointing at a mirror.

## Tracking upstream

The address is hard-coded in the script and points at upstream `master`:

```sh
UPSTREAM_BASE_URL="${FGETPRIORITY_BASE_URL:-https://raw.githubusercontent.com/aerath-stuff/fgetpriority/master/kernel}"
```

There is no version to trace, so every upstream commit reaches the next build, and an upstream change to a struct field or to a syscall dependency fails the built-in compile far away from this module.

To pin, replace `master` in the URL with a commit SHA, or point `FGETPRIORITY_BASE_URL` at an address that carries one. Every build prints one line with the md5 of the ten concatenated files; identical fingerprints mean identical upstream sources:

```text
[fgetpriority] upstream content md5: <md5>
```

## Why the upstream `Makefile` / `Kconfig` stay as-is

The upstream `Makefile` is written as a standalone compilation unit, and the following lands in the kernel tree unchanged, so do not hand-edit it:

```make
obj-$(CONFIG_FGETPRIORITY) += fgetpriority.o
fgetpriority-y := main.o
```

- The `obj-$(...)` and `-y` pair keeps standalone build semantics when the kernel's parent Makefile recurses into `fs/fgetpriority/`.
- `CFLAGS_REMOVE_main.o += -Werror` keeps a batch of upstream warnings from breaking the build.
- `-std=gnu11` → `gnu17` → `gnu23` → `gnu2y` are appended through `cc-option`, the later one winning: the source uses `nullptr`, `constexpr`, and `static_assert`, while kernels before 5.18 defaulted to `gnu89`, so this lifts the language level to the highest the compiler supports.
- `-fno-stack-protector -fno-stack-check`, `CFLAGS_REMOVE_main.o += $(CC_FLAGS_FTRACE)`, and `-pg`: removing them breaks the build or the behavior.

The upstream `Kconfig`'s `default m` also stays as-is (it is the LKM default), and this module overrides it to `=y` in the defconfig.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Integration complete, including "already integrated, download skipped" |
| `1` | Missing `KERNEL_ROOT` / `DEFCONFIG`; missing `$DEFCONFIG` file; no `fs/` tree; download failure or empty file; content check failure; re-check reporting `integration incomplete` |

curl exit codes are not propagated individually; download failures all map to `1`.

## Rollback

Remove the module from `custom_external_modules`; every build starts from a fresh clone, so nothing persists.

To roll back an already integrated tree by hand:

```sh
KERNEL_SRC=<kernel tree root>        # $KERNEL_ROOT/common under GKI
rm -rf "$KERNEL_SRC/fs/fgetpriority"
sed -i '\#^obj-$(CONFIG_FGETPRIORITY) += fgetpriority/$#d' "$KERNEL_SRC/fs/Makefile"
sed -i '\#^source "fs/fgetpriority/Kconfig"$#d' "$KERNEL_SRC/fs/Kconfig"
sed -i '/^CONFIG_FGETPRIORITY=/d' "$DEFCONFIG"
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `KERNEL_ROOT is not set (run this through ABK)` / `DEFCONFIG is not set ...` | Not running through ABK, or running by hand without the variables |
| `defconfig not found: <path>` | `$DEFCONFIG` does not exist, usually a wrong variable or a different layout |
| `no fs/ tree under <KERNEL_SRC>` | `KERNEL_ROOT` is not a kernel tree and has no `common/` |
| `warning: no arch/arm64 in <KERNEL_SRC>; fgetpriority is ARM64-only` | The target tree is not arm64 and the built-in compile will fail on the `static_assert` |
| `CONFIG_KALLSYMS=y in <path>` | Informational, the prerequisite is met |
| `warning: CONFIG_KALLSYMS is explicitly off in <path>; Kconfig drops CONFIG_FGETPRIORITY` | Some defconfig says `# CONFIG_KALLSYMS is not set` and the symbol will be dropped. Delete that line or use another fragment |
| `warning: CONFIG_KALLSYMS not seen in <path> or the arm64 defaults; Kconfig may drop CONFIG_FGETPRIORITY` | None of the three defconfigs mentions KALLSYMS, so the symbol may be dropped silently. Check whether the kernel line `select`s it elsewhere, or use another fragment |
| `download failed: <base>` | `raw.githubusercontent.com` unreachable, or a mirror 404. The directory has been removed, so a retry is safe |
| `content check failed in <dir> (upstream changed or a mirror returned an error page)` | A proxy or mirror returned an error page, or upstream changed the markers. The directory has been removed; switch `FGETPRIORITY_BASE_URL` or check the network policy |
| `integration incomplete: want 10 files ...` | Files or the `fs/` wiring did not land, usually a failed write or an abnormal kernel tree |
| Compile error `ARM64 only!` | The target is not arm64 |
| The kernel builds but the feature is absent | `CONFIG_KALLSYMS` is off (look for the warning in the build log), or `CONFIG_FGETPRIORITY` was dropped by Kconfig |

## License

`setup.sh`, `module.conf`, `README.md`, and `README-EN.md` are released under **GPL-3.0-only**; see [`LICENSE`](LICENSE).

This repository contains no upstream `fgetpriority` source and only fetches it at build time; the integrated source is distributed under its own **GPL-2.0-only** license, see [aerath-stuff/fgetpriority](https://github.com/aerath-stuff/fgetpriority). The two do not conflict: this repository only downloads and wires `fs/`, copying and modifying nothing upstream.
