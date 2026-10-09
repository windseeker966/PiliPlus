#!/usr/bin/env bash
# 本地编译 Android arm64 release APK，步骤与 .github/workflows/build.yml + lib/scripts/patch.ps1 一致：
#   1. 给专用 Flutter SDK 打补丁；
#   2. flutter pub get，并给 pub 缓存里的 material_ui 打补丁；
#   3. 用提交数作版本号编译。
# 与官方脚本的区别：不修改全局 git 配置；Flutter SDK 和 pub 缓存放在项目内的 .toolchain/
#（已写入 .git/info/exclude），打过补丁的 SDK 和包不影响其他 Flutter 项目。
# 首次使用需准备 SDK：git clone --depth 1 --branch <pubspec 中的 flutter 版本> \
#   https://github.com/flutter/flutter.git .toolchain/flutter
#
# 用法：tool/build_android_local.sh            输出 build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#       BUILD_MODE=profile tool/build_android_local.sh
#                                              输出 app-arm64-v8a-profile.apk，包名与正式版相同（覆盖安装、保留数据）；
#                                              性能接近 release，且可用 adb shell run-as 读取应用数据
# 可用环境变量覆盖：BUILD_MODE（release / profile，默认 release）、FLUTTER_ROOT、PUB_CACHE、JAVA_HOME、ANDROID_HOME
set -euo pipefail

BUILD_MODE="${BUILD_MODE:-release}"
case "$BUILD_MODE" in
  release | profile) ;;
  *) echo "BUILD_MODE 只能是 release 或 profile：$BUILD_MODE" >&2; exit 1 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export FLUTTER_ROOT="${FLUTTER_ROOT:-$REPO/.toolchain/flutter}"
export PUB_CACHE="${PUB_CACHE:-$REPO/.toolchain/pub-cache}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$FLUTTER_ROOT/bin:$PATH"

flutter_patches=(
  modal_barrier text_selection mouse_cursor image_anim layout_builder
  navigation_drawer popup_menu fab null_safety_for_selectable_region
  selectable_region editable_text text_field scroll_position scrollable
  scrollable_gesture draggable_scrollable_sheet scaffold text text_painter
  sliver refresh_indicator double_tap_gesture
  # android
  bottom_sheet_android scroll_view navigator
)
material_patches=(
  modal_barrier_material navigation_drawer popup_menu fab text_field
  scaffold refresh_indicator tabs
  # android
  bottom_sheet_android
)

echo "==> 给 Flutter SDK 打补丁：$FLUTTER_ROOT"
git -C "$FLUTTER_ROOT" reset --hard -q HEAD
for name in "${flutter_patches[@]}"; do
  git -C "$FLUTTER_ROOT" apply "$REPO/lib/scripts/$name.patch"
done

cd "$REPO"
echo "==> flutter pub get（PUB_CACHE=$PUB_CACHE）"
rm -rf "$PUB_CACHE"/hosted/pub.dev/material_ui-*
flutter pub get

material_dir="$(ls -d "$PUB_CACHE"/hosted/pub.dev/material_ui-* | tail -1)"
echo "==> 给 material_ui 打补丁：$material_dir"
for name in "${material_patches[@]}"; do
  # pub 缓存位于本仓库内，git apply 会按本仓库根目录解析路径并静默跳过，因此用 patch。
  tr -d '\r' < "$REPO/lib/scripts/material/$name.patch" | patch -d "$material_dir" -p1 --forward --silent
done

version_name="$(sed -nE 's/^version:[[:space:]]*([0-9.]+).*/\1/p' pubspec.yaml)"
version_code="$(git rev-list --count HEAD)"
commit_hash="$(git rev-parse HEAD)"
version_name="$version_name-${commit_hash:0:9}"

echo "==> 编译 $version_name+$version_code（$BUILD_MODE）"
flutter build apk "--$BUILD_MODE" --no-pub \
  --target-platform android-arm64 --split-per-abi \
  --build-name "$version_name" --build-number "$version_code" \
  --dart-define "pili.name=$version_name" \
  --dart-define "pili.code=$version_code" \
  --dart-define "pili.hash=$commit_hash" \
  --dart-define "pili.time=$(date +%s)"

ls -la "$REPO/build/app/outputs/flutter-apk/"*arm64*"$BUILD_MODE".apk
