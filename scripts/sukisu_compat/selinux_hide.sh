#!/usr/bin/env bash
# SukiSU-Nova SELinux Hide：開機自動啟用 + LSM hook 相容修補
#
# SELinux Hide 必須在 boot_completed 前啟用，否則上游會釋放 backup_sepolicy。
# 本補丁把 selinux_hide 設為核心預設 forced feature，並保留 force_feature
# boot parameter 的優先權（使用者明確指定時不覆蓋）。
#
# 6.1 的 LSM hlist 在 ThinLTO/KCFI 下可能保存 .llvm.* 函式別名，
# 與 kallsyms 的 selinux_setprocattr 起始位址不完全相等；以符號範圍比對
# 修正上游 lsm_hook.c 的 exact-pointer miss。
#
# 用法：在 KERNEL_ROOT 工作目錄執行 selinux_hide.sh KernelSU

set -euo pipefail

KSU_DIR="$1"
FEATURE_FILE="$KSU_DIR/kernel/policy/feature.c"
HIDE_FILE="$KSU_DIR/kernel/feature/selinux_hide.c"
LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
KSU_MAIN_FILE="$KSU_DIR/kernel/ksu_main.c"
KSUD_FILE="$KSU_DIR/kernel/runtime/ksud.c"

fail() {
  echo "::error::SukiSU-Nova SELinux Hide 自動啟用修補失敗：$1"
  exit 1
}

for f in "$FEATURE_FILE" "$HIDE_FILE" "$LSM_FILE" "$KSU_MAIN_FILE" "$KSUD_FILE"; do
  [ -f "$f" ] || fail "找不到必要來源檔案：$f"
done

grep -q 'KSU_FEATURE_SELINUX_HIDE' "$FEATURE_FILE" \
  || fail "feature.c 不含 KSU_FEATURE_SELINUX_HIDE"
grep -q 'ksu_register_feature_handler(&selinux_hide_handler)' "$HIDE_FILE" \
  || fail "selinux_hide.c 未註冊 SELinux Hide feature handler"
grep -q 'ksu_feature_apply_forced();' "$KSU_MAIN_FILE" \
  || fail "ksu_main.c 缺少核心初始化時的 forced feature 套用入口"
grep -q 'ksu_feature_apply_forced();' "$KSUD_FILE" \
  || fail "ksud.c 缺少 second-stage / post-fs-data forced feature 重試入口"
grep -q 'ksu_selinux_hide_drop_backup_if_unused();' "$KSUD_FILE" \
  || fail "ksud.c 缺少 backup_sepolicy 啟動生命週期管理"

echo "設定 SukiSU-Nova SELinux Hide 開機自動啟用..."
python3 - "$FEATURE_FILE" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = "GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART"
if marker not in text:
    assignment = "    forced_values[KSU_FEATURE_SELINUX_HIDE] = 1;"
    if assignment in text:
        raise SystemExit("feature.c 已有 SELinux Hide 強制設定，但缺少本工作流標記；拒絕重複注入")

    anchor = '    pr_info("feature: feature management initialized\\n");'
    if text.count(anchor) != 1:
        raise SystemExit("feature.c 的 ksu_feature_init() 結構已變更，找不到唯一初始化錨點")

    injection = """    /* GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART */
    if (!test_bit(KSU_FEATURE_SELINUX_HIDE, forced_mask)) {
        forced_values[KSU_FEATURE_SELINUX_HIDE] = 1;
        set_bit(KSU_FEATURE_SELINUX_HIDE, forced_mask);
        set_bit(KSU_FEATURE_SELINUX_HIDE, forced_pending);
        pr_info("feature: selinux_hide auto-enabled by build workflow\\n");
    }

"""
    text = text.replace(anchor, injection + anchor, 1)
    path.write_text(text, encoding="utf-8")

check = [
    "GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART",
    "forced_values[KSU_FEATURE_SELINUX_HIDE] = 1;",
    "set_bit(KSU_FEATURE_SELINUX_HIDE, forced_mask);",
    "set_bit(KSU_FEATURE_SELINUX_HIDE, forced_pending);",
]
for token in check:
    if token not in text:
        raise SystemExit("SELinux Hide 自動啟用驗證失敗：" + token)
print("feature.c：SELinux Hide 已設為開機 forced=1")
PYEOF

if grep -q 'target_name' "$LSM_FILE" && grep -q 'security_hook_heads' "$LSM_FILE"; then
echo "套用 SELinux setprocattr LSM 符號範圍相容修補..."
python3 - "$LSM_FILE" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "GKI_WORKFLOW_SELINUX_SETPROCATTR_RANGE_MATCH"

if marker not in text:
    variables = """    unsigned long heads_addr;
    struct hlist_head *head;
    struct security_hook_list *selected_entry = NULL;
    void **selected_slot = NULL;
    void *selected_origin = NULL;
"""
    if text.count(variables) != 1:
        raise SystemExit("lsm_hook.c hlist 區域變數錨點不唯一；拒絕套用不確定修補")

    text = text.replace(
        variables,
        variables + "    unsigned long target_size = 0;\n",
        1,
    )

    target_log = '    pr_info("target: 0x%lx %pSb\\n", (unsigned long)target, target);\n'
    if text.count(target_log) != 1:
        raise SystemExit("lsm_hook.c target 記錄錨點不唯一")

    size_lookup = """    /* GKI_WORKFLOW_SELINUX_SETPROCATTR_RANGE_MATCH */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)
    if (!strcmp(target_name, "selinux_setprocattr"))
        kallsyms_lookup_size_offset((unsigned long)target, &target_size, NULL);
#endif
"""
    text = text.replace(target_log, target_log + size_lookup, 1)

    hlist_start = "    head = (struct hlist_head *)heads_addr;"
    idx = text.find(hlist_start)
    if idx < 0:
        raise SystemExit("lsm_hook.c 找不到 6.1 以下的 security_hook_heads hlist 區段")

    prefix, tail = text[:idx], text[idx:]
    old = """            void *current_origin = READ_ONCE(*slot);
            int j;
            for (j = 0; j < ksu_lsm_hook_count; j++) {
                if (ksu_lsm_hook_entries[j].hook->replacement == current_origin) {
                    current_origin = ksu_lsm_hook_entries[j].hook->original;
                    break;
                }
            }
            if (current_origin == hook->replacement) {
"""
    new = """            void *current_origin = READ_ONCE(*slot);
            int j;
            bool target_match;
            for (j = 0; j < ksu_lsm_hook_count; j++) {
                if (ksu_lsm_hook_entries[j].hook->replacement == current_origin) {
                    current_origin = ksu_lsm_hook_entries[j].hook->original;
                    break;
                }
            }
            target_match = current_origin == target;
            if (!target_match && target_size) {
                unsigned long origin_addr = (unsigned long)current_origin;
                unsigned long target_addr = (unsigned long)target;
                target_match = origin_addr >= target_addr &&
                               origin_addr - target_addr < target_size;
            }
            if (current_origin == hook->replacement) {
"""
    if tail.count(old) != 1:
        raise SystemExit("lsm_hook.c hlist callback比對錨點不唯一")
    tail = tail.replace(old, new, 1)

    old_match = "            if (current_origin == target) {\n"
    if tail.count(old_match) != 1:
        raise SystemExit("lsm_hook.c hlist target 比對錨點不唯一")
    tail = tail.replace(old_match, "            if (target_match) {\n", 1)

    text = prefix + tail
    path.write_text(text, encoding="utf-8")

if marker not in text:
    raise SystemExit("LSM 符號範圍修補標記不存在")
if "origin_addr - target_addr < target_size" not in text:
    raise SystemExit("LSM 符號範圍比對驗證失敗")
print("lsm_hook.c：selinux_setprocattr 支援 KCFI/ThinLTO 符號別名範圍比對")
PYEOF

grep -q 'GKI_WORKFLOW_SELINUX_HIDE_AUTOSTART' "$FEATURE_FILE" \
  || fail "SELinux Hide 自動啟用標記缺失"
grep -q 'GKI_WORKFLOW_SELINUX_SETPROCATTR_RANGE_MATCH' "$LSM_FILE" \
  || fail "SELinux setprocattr LSM 相容標記缺失"
grep -q 'origin_addr - target_addr < target_size' "$LSM_FILE" \
  || fail "SELinux setprocattr 符號範圍比對缺失"
else
  echo "目前 builtin 分支未使用 selinux_setprocattr 動態 LSM hlist hook，略過僅適用於該 hook 的 KCFI/LTO 修補"
fi

echo "SukiSU-Nova SELinux Hide 自動啟用修補完成"
