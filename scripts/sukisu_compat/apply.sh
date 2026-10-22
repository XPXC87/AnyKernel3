#!/usr/bin/env bash
# SukiSU 内核源码 API 兼容补丁（SukiSU-Ultra builtin / main 分支均适用）
#
# 背景：
#   1) builtin 分支 kernel/hook/lsm_hook.c 仍以旧签名
#      security_add_hooks(hooks, count, "ksu") 注册 LSM 钩子，
#      6.8+ 内核要求 (hooks, count, const struct lsm_id *)，
#      android16-6.12 GKI 编译报 -Wincompatible-pointer-types（-Werror）；
#   2) <kpm>/super_access.c 引用 netlink_kernel_cfg.cb_mutex，
#      该成员在 Linux 6.11 被上游移除，KPM 开启时 6.11+ 内核编译失败
#      （上游 2026-10-19 重构后该文件由 kernel/kpm/ 迁至
#        kernel/extension/kpm/，本脚本按实际路径定位，不再写死）；
#   3) builtin 在 app 启动路径对管理器/授权应用 disable_seccomp()，
#      管理器首页 "Seccomp 状态" 显示"未启用"；改为对齐 main 分支/BakaSU
#      的过滤模式（保留 seccomp 过滤器 + action cache 放行 reboot）。
#
# 已由上游修复、本仓库随之移除的适配（核对 builtin 5ef32ad / main 31255c4）：
#   - arch.h 缺失：builtin 已自带 kernel/arch.h（与本仓库旧副本逐字节一致）
#   - EVENT_SERVICES 缺失 / rules.c 重复声明：builtin 已随 UAPI 6 同步修复
#   - pkg_observer 的 track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS)：已改回 false
#   - supercall.h 的 KSU_IOCTL_KPM 笔误 / KSU_IOCTL_MANAGER 缺声明：
#     上游已把 KPM / MANAGER 等并入统一的 KSU_IOCTL_EXTENSION，旧常量不复存在
#   - throne_tracker 的 crown_manager 裸 return / pkg 作用域：上游已修正
#
# 修复均以内容检测守卫，上游自行修复后自动跳过，重复执行幂等。
#
# 用法: apply.sh [KernelSU 目录]（调用方工作目录需为 $KERNEL_ROOT）

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU 兼容补丁已跳过::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API 兼容补丁** 已自动跳过：$1（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "未找到 KernelSU 目录: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 lsm_id 兼容代码，跳过"
  else
    echo "应用 lsm_id 兼容补丁 (6.8+ security_add_hooks 新签名)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "lsm_id 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "lsm_id 兼容补丁应用后校验失败"
    echo "lsm_hook.c: 6.8+ 已切换为 struct lsm_id 注册"
  fi
else
  echo "lsm_hook.c 不存在或无需 lsm_id 兼容补丁，跳过"
fi

# 位置随上游重构迁移过（kernel/kpm/ -> kernel/extension/kpm/），按实际路径定位，
# 避免守卫路径写死导致补丁静默跳过（6.12 会因此直接编译失败）
SUPER_REL=""
for cand in kernel/extension/kpm/super_access.c kernel/kpm/super_access.c; do
  if [ -f "$KSU_DIR/$cand" ]; then
    SUPER_REL="$cand"
    break
  fi
done
if [ -z "$SUPER_REL" ] && [ -d "$KSU_DIR/kernel" ]; then
  SUPER_REL="$(cd "$KSU_DIR" && find kernel -type f -name super_access.c -path '*kpm*' 2>/dev/null | head -n 1)"
fi

if [ -n "$SUPER_REL" ] && grep -q 'DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)' "$KSU_DIR/$SUPER_REL"; then
  if grep -q 'KERNEL_VERSION(6, 11, 0)' "$KSU_DIR/$SUPER_REL"; then
    echo "$SUPER_REL 已包含 cb_mutex 版本守卫，跳过"
  else
    echo "应用 cb_mutex 兼容补丁 (6.11+ 移除 netlink_kernel_cfg.cb_mutex, 目标 $SUPER_REL)..."
    # 补丁头固定为旧路径 kernel/kpm/，这里改写为实际路径后应用
    sed -e "s|kernel/kpm/super_access.c|$SUPER_REL|g" "$COMPAT_DIR/sukisu-cb-mutex-6.11.patch" \
      | patch -p1 --forward -d "$KSU_DIR" \
      || fail "cb_mutex 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'KERNEL_VERSION(6, 11, 0)' "$KSU_DIR/$SUPER_REL" \
      || fail "cb_mutex 兼容补丁应用后校验失败"
    echo "$SUPER_REL: 6.11+ 已跳过 cb_mutex 成员"
  fi
else
  echo "未找到 kpm/super_access.c 或无需 cb_mutex 兼容补丁，跳过"
fi

# ---- Seccomp 过滤模式（builtin 分支）----
# 背景：builtin 分支在 app 启动路径（zygote setresuid 钩子）对管理器与授权
# 应用直接调用 disable_seccomp()，管理器进程自身的 seccomp 过滤器被清除，
# 管理器首页 "Seccomp 状态" 显示"未启用"。main 分支 / BakaSU 的对应实现是
# 保留过滤器（"过滤模式"），仅通过 seccomp action cache（GKI 5.10+ backport）
# 放行 reboot。
# 处理：改写 lsm_hook.c 的 6 处 disable_seccomp() 调用点为 cache-allow 形式，
# 分发 infra/seccomp_cache.c/h 并在 ksu.c（上游重构后为 ksu_main.c）聚合编译；>=5.10 保留过滤器，
# <5.10 维持 disable_seccomp() 原行为（action cache 不存在）。
# 守卫：仅命中 builtin 的 handle_zygote_setresuid 时执行，main 分支自动跳过；
# 上游自行修复后幂等跳过。
if [ -f "$LSM_FILE" ] && grep -q 'handle_zygote_setresuid' "$LSM_FILE"; then
  if grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 seccomp 过滤模式逻辑，跳过"
  else
    echo "应用 seccomp 过滤模式补丁 (对齐 main 分支/BakaSU：管理器与授权应用保留 seccomp 过滤器)..."
    [ -d "$KSU_DIR/kernel/infra" ] || fail "未找到 $KSU_DIR/kernel/infra 目录，SukiSU builtin 结构可能已变化"
    cp "$COMPAT_DIR/seccomp_cache.h" "$KSU_DIR/kernel/infra/seccomp_cache.h" \
      || fail "seccomp_cache.h 分发失败"
    cp "$COMPAT_DIR/seccomp_cache.c" "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c 分发失败"
    python3 "$COMPAT_DIR/seccomp_filter_mode.py" "$KSU_DIR" \
      || fail "seccomp 过滤模式补丁应用失败（SukiSU builtin 上游代码可能已变化）"
    grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE" \
      || fail "seccomp 过滤模式补丁应用后校验失败 (lsm_hook.c)"
    # 聚合编译文件随上游重构更名（kernel/ksu.c -> kernel/ksu_main.c），按实际路径校验
    KSU_AGG=""
    for cand in kernel/ksu.c kernel/ksu_main.c; do
      if [ -f "$KSU_DIR/$cand" ]; then
        KSU_AGG="$KSU_DIR/$cand"
        break
      fi
    done
    if [ -z "$KSU_AGG" ] || ! grep -q '#include "infra/seccomp_cache.c"' "$KSU_AGG"; then
      fail "seccomp 过滤模式补丁应用后校验失败 (聚合编译文件 ksu.c/ksu_main.c)"
    fi
    grep -q '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c 版本守卫校验失败"
    echo "seccomp 过滤模式已启用：管理器首页 Seccomp 状态将显示\"过滤模式\""
  fi
else
  echo "lsm_hook.c 无 builtin setresuid 路径（main 分支已内置过滤模式），跳过 seccomp 过滤模式补丁"
fi

echo "SukiSU API 兼容补丁处理完成"
