#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

UPSTREAM_BASE_URL="${FGETPRIORITY_BASE_URL:-https://raw.githubusercontent.com/aerath-stuff/fgetpriority/master/kernel}"
FS_DIR_NAME="fgetpriority"
SRC_FILES="main.c kernel.h arch.h arm64_branch_insn.h routine.h routine_kp.c routine_raw.c Kconfig Makefile LICENSE"

: "${KERNEL_ROOT:?KERNEL_ROOT is not set (run this through ABK)}"
: "${DEFCONFIG:?DEFCONFIG is not set (run this through ABK)}"

[ -f "$DEFCONFIG" ] \
  || { echo "[fgetpriority] defconfig not found: $DEFCONFIG" >&2; exit 1; }

# GKI 的源码根是 $KERNEL_ROOT/common
if [ -d "$KERNEL_ROOT/common/fs" ]; then
  KERNEL_SRC="$KERNEL_ROOT/common"
else
  KERNEL_SRC="$KERNEL_ROOT"
fi

FS_DIR="$KERNEL_SRC/fs"
[ -d "$FS_DIR" ] || { echo "[fgetpriority] no fs/ tree under $KERNEL_SRC" >&2; exit 1; }

# 上游 main.c 有 static_assert，非 arm64 在编译期失败
[ -d "$KERNEL_SRC/arch/arm64" ] \
  || echo "[fgetpriority] warning: no arch/arm64 in $KERNEL_SRC; fgetpriority is ARM64-only" >&2

# CONFIG_KALLSYMS 关掉时 Kconfig 静默丢弃本符号，而它通常只写在默认 defconfig 里
CONFIG_DIR="$KERNEL_SRC/arch/arm64/configs"
KALLSYMS_STATE=""
KALLSYMS_EVIDENCE=""
for df in "$DEFCONFIG" "$CONFIG_DIR/gki_defconfig" "$CONFIG_DIR/defconfig"; do
  [ -f "$df" ] || continue
  if grep -qE '^CONFIG_KALLSYMS=y$' "$df"; then
    KALLSYMS_STATE="enabled"
    KALLSYMS_EVIDENCE="$df"
    break
  fi
  if grep -qE '^# CONFIG_KALLSYMS is not set$' "$df"; then
    KALLSYMS_STATE="disabled"
    KALLSYMS_EVIDENCE="$df"
    break
  fi
done
case "$KALLSYMS_STATE" in
  enabled) echo "[fgetpriority] CONFIG_KALLSYMS=y in $KALLSYMS_EVIDENCE" ;;
  disabled) echo "[fgetpriority] warning: CONFIG_KALLSYMS is explicitly off in $KALLSYMS_EVIDENCE; Kconfig drops CONFIG_FGETPRIORITY" >&2 ;;
  *) echo "[fgetpriority] warning: CONFIG_KALLSYMS not seen in $DEFCONFIG or the arm64 defaults; Kconfig may drop CONFIG_FGETPRIORITY" >&2 ;;
esac

# 上游只有源码，没有安装脚本，下载与接线由这里补
TARGET_DIR="$FS_DIR/$FS_DIR_NAME"
MAKEFILE_LINE='obj-$(CONFIG_FGETPRIORITY) += fgetpriority/'
KCONFIG_LINE='source "fs/fgetpriority/Kconfig"'

files_present() {
  for f in $SRC_FILES; do [ -s "$TARGET_DIR/$f" ] || return 1; done
}

# 代理可能回 200 加非空错误页，只有内容标记拦得住
content_ok() {
  grep -qs 'static int __init fgetpriority_init(void)' "$TARGET_DIR/main.c" \
    && grep -qs 'config FGETPRIORITY' "$TARGET_DIR/Kconfig" \
    && grep -qs 'fgetpriority-y := main.o' "$TARGET_DIR/Makefile"
}

integrated() {
  files_present || return 1
  content_ok || return 1
  grep -qF "$MAKEFILE_LINE" "$FS_DIR/Makefile" || return 1
  grep -qF "$KCONFIG_LINE" "$FS_DIR/Kconfig" || return 1
}

if integrated; then
  echo "[fgetpriority] already integrated at $TARGET_DIR; skipping download"
else
  echo "[fgetpriority] fetching from $UPSTREAM_BASE_URL"
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  incomplete=""
  for f in $SRC_FILES; do
    curl -fLSs --retry 3 --retry-delay 2 --connect-timeout 20 \
      -o "$TARGET_DIR/$f" "$UPSTREAM_BASE_URL/$f" || incomplete=1
    [ -s "$TARGET_DIR/$f" ] || incomplete=1
  done
  [ -z "$incomplete" ] \
    || { rm -rf "$TARGET_DIR"; echo "[fgetpriority] download failed: $UPSTREAM_BASE_URL" >&2; exit 1; }
  content_ok \
    || { rm -rf "$TARGET_DIR"; echo "[fgetpriority] content check failed in $TARGET_DIR (upstream changed or a mirror returned an error page)" >&2; exit 1; }
fi

# 跟随 master 没有版本号可追溯，用内容指纹代替，接线前打印以便接线失败时也留得下
echo "[fgetpriority] upstream content md5: $( ( for f in $SRC_FILES; do cat "$TARGET_DIR/$f"; done ) | md5sum | cut -d' ' -f1 )"

if ! grep -qF "$MAKEFILE_LINE" "$FS_DIR/Makefile"; then
  printf '\n%s\n' "$MAKEFILE_LINE" >> "$FS_DIR/Makefile"
fi

if ! grep -qF "$KCONFIG_LINE" "$FS_DIR/Kconfig"; then
  # 插在最后一个 endmenu 前才留在 File Systems 菜单内，没有 endmenu 就追加
  awk -v ins="$KCONFIG_LINE" '
    { l[NR] = $0 }
    END { last = 0; for (i = 1; i <= NR; i++) if (l[i] ~ /^[ \t]*endmenu[ \t]*$/) last = i
          for (i = 1; i <= NR; i++) { if (i == last) print ins; print l[i] }
          if (!last) print ins }' "$FS_DIR/Kconfig" > "$FS_DIR/Kconfig.abk.tmp"
  mv -f "$FS_DIR/Kconfig.abk.tmp" "$FS_DIR/Kconfig"
fi

integrated \
  || { echo "[fgetpriority] integration incomplete: want 10 files in $TARGET_DIR and wiring in fs/Makefile, fs/Kconfig" >&2; exit 1; }

# 上游是 tristate + default m，内核本体需 =y
if grep -q '^CONFIG_FGETPRIORITY=y$' "$DEFCONFIG"; then
  echo "[fgetpriority] CONFIG_FGETPRIORITY=y already in $DEFCONFIG"
elif grep -q '^CONFIG_FGETPRIORITY=' "$DEFCONFIG"; then
  sed -i 's/^CONFIG_FGETPRIORITY=.*/CONFIG_FGETPRIORITY=y/' "$DEFCONFIG"
  echo "[fgetpriority] rewrote CONFIG_FGETPRIORITY=y in $DEFCONFIG"
elif grep -q '^# CONFIG_FGETPRIORITY is not set$' "$DEFCONFIG"; then
  sed -i 's/^# CONFIG_FGETPRIORITY is not set$/CONFIG_FGETPRIORITY=y/' "$DEFCONFIG"
  echo "[fgetpriority] enabled CONFIG_FGETPRIORITY=y in $DEFCONFIG"
else
  printf 'CONFIG_FGETPRIORITY=y\n' >> "$DEFCONFIG"
  echo "[fgetpriority] appended CONFIG_FGETPRIORITY=y to $DEFCONFIG"
fi

echo "[fgetpriority] done"
