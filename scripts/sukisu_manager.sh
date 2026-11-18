#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:-release}"
KSU_DIR="${2:-KernelSU}"
API="https://git.zako.shirkneko.top:20004/api/v1/repos/shirkneko/SukiSU"

case "$CHANNEL" in
  最新*|latest*|HEAD*) ROLLING=true ;;
  *) ROLLING=false ;;
esac

RELEASE=""
if [ "$ROLLING" = false ]; then
  RELEASE=$(curl -fsSL --retry 3 --max-time 30 "$API/releases?limit=40" | jq -c '
    [ .[]
      | select((.draft | not) and (.prerelease | not))
      | select(.tag_name | test("(?i)^(manager-ci|manager_ci|nightly|latest|ci)$") | not)
      | select(any(.assets[]?;
          (.name | test("release\\.apk$"; "i")) and
          (.name | test("(?i)debug|spoofed") | not))) ]
    | .[0] // empty
  ')
  if [ -z "$RELEASE" ]; then
    echo "::notice::SukiSU-Nova 没有正式版 APK，改用 manager-ci"
    ROLLING=true
  fi
fi

COMMIT=""
if [ "$ROLLING" = false ]; then
  TAG=$(printf '%s' "$RELEASE" | jq -r '.tag_name')
  COMMIT=$(git -C "$KSU_DIR" rev-parse --verify "${TAG}^{commit}")
else
  # manager-ci 会在 main 更新后异步重建；锁定本次构建检出的 HEAD，
  # 等待上游 APK 的 versionCode 与该提交对应的版本一致。
  COMMIT=$(git -C "$KSU_DIR" rev-parse origin/main)
fi
if [ -z "$COMMIT" ]; then
  echo "::error::无法在 SukiSU-Nova main 中找到对应的内核提交"
  exit 1
fi
COUNT=$(git -C "$KSU_DIR" rev-list --count "$COMMIT")
ACTUAL_VERSION=$((30000 + COUNT + 996))

MATCHED=false
MAX_ATTEMPTS=20
for ATTEMPT in $(seq 1 "$MAX_ATTEMPTS"); do
  if [ "$ROLLING" = true ]; then
    if ! RELEASE=$(curl -fsSL --retry 2 --max-time 30 -H "Cache-Control: no-cache" "$API/releases/tags/manager-ci"); then
      echo "::warning::获取 SukiSU-Nova manager-ci 失败（第 $ATTEMPT/$MAX_ATTEMPTS 次）"
      if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
        sleep 30
        continue
      fi
      echo "::error::等待上游 manager-ci 失败，无法取得管理器"
      exit 1
    fi
  fi

  TAG=$(printf '%s' "$RELEASE" | jq -r '.tag_name')
  ASSETS=$(printf '%s' "$RELEASE" | jq -r '
    [ .assets[]?
      | select(.name | test("release\\.apk$"; "i"))
      | select(.name | test("(?i)debug|spoofed") | not) ]
    | sort_by(if (.name | test("(?i)universal")) then 0
              elif (.name | test("(?i)arm64-v8a")) then 1 else 2 end)
    | .[] | [.name, .browser_download_url] | @tsv
  ')
  if [ -z "$ASSETS" ]; then
    if [ "$ROLLING" = true ] && [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      echo "::warning::SukiSU-Nova manager-ci 尚未發布可用 APK（第 $ATTEMPT/$MAX_ATTEMPTS 次），30 秒後重試"
      sleep 30
      continue
    fi
    echo "::error::SukiSU-Nova $TAG 中没有可用的管理器 APK"
    exit 1
  fi

  IFS=$'\t' read -r APK_NAME _ <<< "$(printf '%s\\n' "$ASSETS" | head -n 1)"
  APK_NAME="${APK_NAME%$'\\r'}"
  if [[ "$APK_NAME" =~ _([0-9]+)(-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal))?-release\\.apk$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "::error::无法从 SukiSU-Nova APK 文件名解析版本: $APK_NAME"
    exit 1
  fi

  if [ "$VERSION" -eq "$ACTUAL_VERSION" ]; then
    MATCHED=true
    break
  fi

  if [ "$ROLLING" = false ]; then
    echo "::error::SukiSU-Nova $TAG 的 APK 版本 $VERSION 与标签提交对应版本 $ACTUAL_VERSION 不一致"
    exit 1
  fi

  if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
    echo "::notice::SukiSU-Nova manager-ci 版本 $VERSION，main HEAD 版本 $ACTUAL_VERSION；上游 CI 尚未完成，30 秒后重新检查（$ATTEMPT/$MAX_ATTEMPTS）"
    sleep 30
  fi
done

if [ "$MATCHED" != true ]; then
  echo "::error::等待上游 SukiSU-Nova manager-ci 超时；需要版本 $ACTUAL_VERSION，最后取得版本 ${VERSION:-未知}"
  exit 1
fi

mkdir -p manager-artifacts
while IFS=$'\t' read -r NAME URL; do
  NAME="${NAME%$'\\r'}"
  URL="${URL%$'\\r'}"
  curl -fsSL --retry 3 --max-time 300 -o "manager-artifacts/$(basename "$NAME")" "$URL"
done <<< "$ASSETS"
echo "SukiSU-Nova $TAG: 管理器 $VERSION，内核版本来源提交 $COMMIT"
echo "MANAGER_VERSION=$VERSION" >> "$GITHUB_ENV"
{
  echo "managerVer=$VERSION"
  echo "ksuCommit=$COMMIT"
  if [ "$ROLLING" = false ]; then
    echo "channelTag=$TAG"
  fi
} >> "$GITHUB_OUTPUT"
