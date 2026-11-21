#!/usr/bin/env bash
# SukiSU-Nova SELinux Hide：開機預設啟用，但保留管理器自由開關
#
# 在 init second_stage 完成 apply_kernelsu_rules() 後啟用，確保 backup_sepolicy
# 已建立。使用一般 Feature setter，不設定 forced_mask，因此管理器仍可 set 0/1。
# 若使用者透過 force_feature boot parameter 明確指定，則尊重該設定。
#
# 用法：在 KERNEL_ROOT 工作目錄執行 selinux_hide.sh KernelSU

set -euo pipefail

KSU_DIR="$1"
FEATURE_FILE="$KSU_DIR/kernel/policy/feature.c"
HIDE_FILE="$KSU_DIR/kernel/feature/selinux_hide.c"
KSU_MAIN_FILE="$KSU_DIR/kernel/ksu_main.c"
KSUD_FILE="$KSU_DIR/kernel/runtime/ksud.c"

fail() {
  echo "::error::SukiSU-Nova SELinux Hide 修補失敗：$1"
  exit 1
}

for f in "$FEATURE_FILE" "$HIDE_FILE" "$KSU_MAIN_FILE" "$KSUD_FILE"; do
  [ -f "$f" ] || fail "找不到必要來源檔案：$f"
done

grep -q 'KSU_FEATURE_SELINUX_HIDE' "$FEATURE_FILE" \
  || fail "feature.c 不含 KSU_FEATURE_SELINUX_HIDE"
grep -q 'ksu_register_feature_handler(&selinux_hide_handler)' "$HIDE_FILE" \
  || fail "selinux_hide.c 未註冊 SELinux Hide feature handler"
grep -q 'ksu_feature_apply_forced();' "$KSU_MAIN_FILE" \
  || fail "ksu_main.c 缺少 forced feature 初始化入口"
grep -q 'ksu_feature_apply_forced();' "$KSUD_FILE" \
  || fail "ksud.c 缺少 second-stage / post-fs-data forced feature 套用入口"
grep -q 'ksu_selinux_hide_drop_backup_if_unused();' "$KSUD_FILE" \
  || fail "ksud.c 缺少 backup_sepolicy 生命週期管理"

echo "設定 SELinux Hide 開機預設啟用（保留管理器開關）..."
python3 - "$FEATURE_FILE" "$KSUD_FILE" <<'PYEOF'
import pathlib
import re
import sys

feature_path = pathlib.Path(sys.argv[1])
ksud_path = pathlib.Path(sys.argv[2])

feature = feature_path.read_text(encoding="utf-8")
ksud = ksud_path.read_text(encoding="utf-8")

# 移除舊版工作流插入的 forced feature 區塊，避免管理器 set_feature 被 -EPERM 拒絕。
old_marker = "GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART"
if old_marker in feature:
    pattern = re.compile(
        r"    /\* GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART \*/\n"
        r"    if \(!test_bit\(KSU_FEATURE_SELINUX_HIDE, forced_mask\)\) \{\n"
        r".*?\n    \}\n\n",
        re.S,
    )
    feature, count = pattern.subn("", feature, count=1)
    if count != 1:
        raise SystemExit("無法安全移除舊版 SELinux Hide forced 注入區塊")
    feature_path.write_text(feature, encoding="utf-8")
    print("feature.c：已移除舊版 forced_mask 強制鎖定")

# 在 init second_stage 的 policy backup 建立後套用一次預設值。
marker = "GKI_WORKFLOW_SELINUX_HIDE_DEFAULT_ONCE"
if marker not in ksud:
    anchor = """                setup_ksu_cred();
                // after apply_kernelsu_rules, so that selinux_hide has its sepolicy backup
                ksu_feature_apply_forced();
                ksu_extension_apply_forced();
"""
    if ksud.count(anchor) != 1:
        raise SystemExit("ksud.c second_stage 初始化錨點不存在或不唯一")

    replacement = """                setup_ksu_cred();
                // after apply_kernelsu_rules, so that selinux_hide has its sepolicy backup
                ksu_feature_apply_forced();
                /* GKI_WORKFLOW_SELINUX_HIDE_DEFAULT_ONCE */
                if (!ksu_feature_is_forced(KSU_FEATURE_SELINUX_HIDE)) {
                    int ret = ksu_set_feature(KSU_FEATURE_SELINUX_HIDE, 1);
                    if (ret)
                        pr_warn("feature: default selinux_hide enable failed: %d\\n", ret);
                }
                ksu_extension_apply_forced();
"""
    ksud = ksud.replace(anchor, replacement, 1)
    ksud_path.write_text(ksud, encoding="utf-8")
    print("ksud.c：second_stage 預設啟用 SELinux Hide，未鎖定 Feature")

if "forced_values[KSU_FEATURE_SELINUX_HIDE] = 1;" in feature:
    raise SystemExit("feature.c 仍存在 SELinux Hide 強制值，拒絕繼續")
if marker not in ksud:
    raise SystemExit("SELinux Hide default-on 注入標記不存在")
if "ksu_feature_is_forced(KSU_FEATURE_SELINUX_HIDE)" not in ksud:
    raise SystemExit("缺少 force_feature 使用者設定優先權檢查")
if "ksu_set_feature(KSU_FEATURE_SELINUX_HIDE, 1)" not in ksud:
    raise SystemExit("缺少一般 Feature setter 預設啟用呼叫")

print("驗證完成：開機預設啟用；forced boot parameter 優先；管理器可自由 set 0/1")
PYEOF

echo "SukiSU-Nova SELinux Hide 管理器可控版修補完成"
