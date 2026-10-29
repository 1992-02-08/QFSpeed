#!/bin/bash
# ============================================================================
#  QFSpeed — SwiftUI 悬浮性能条 构建脚本
#
#  不需要 Xcode 工程：swiftc 直接编译 src/*.swift，手动嵌入 Swift 运行时。
#  私有框架符号来自 libraries/*.tbd（上游 TrollSpeed, MIT）
#  签出 .app 后用 ldid 写 entitlements，压成 IPA，TrollStore 直接装。
#
#  用法: bash build.sh [输出ipa路径]
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="QFSpeed"
BUILD="$ROOT/build"
OUT_IPA="${1:-$ROOT/QFSpeed.ipa}"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS="16.4"

echo ">> SDK     : $SDK_PATH"
echo ">> swiftc  : $(xcrun --find swiftc)"
echo ">> SDK ver : $(xcrun --sdk iphoneos --show-sdk-version)"

rm -rf "$BUILD"
mkdir -p "$BUILD/FW" "$BUILD/obj"

# ---------------------------------------------------------------- 私有框架
# .tbd -> <Name>.framework/<Name>，让 -framework 能解析
for fw in BackBoardServices GraphicsServices SpringBoardServices AssertionServices IOKit; do
  mkdir -p "$BUILD/FW/$fw.framework"
  cp "$ROOT/libraries/$fw.tbd" "$BUILD/FW/$fw.framework/$fw"
done

# IOKit 头文件仍要从 SDK 取一份（否则 import IOKit 找不到）
mkdir -p "$BUILD/FW/IOKit.framework/Headers"
cp -R "$SDK_PATH/System/Library/Frameworks/IOKit.framework/Headers/." \
      "$BUILD/FW/IOKit.framework/Headers/" 2>/dev/null || true

# ---------------------------------------------------------------- 编译 Swift
SOURCES=("$ROOT"/src/*.swift)
if [ ! -e "${SOURCES[0]}" ]; then
  echo "!! 找不到源文件: $ROOT/src/*.swift" >&2
  exit 1
fi
echo ">> 源文件  : ${#SOURCES[@]} 个"

# Swift 是模块化编译的，同时编译所有文件才能互相看到 internal 符号
xcrun -sdk iphoneos swiftc \
  -target arm64-apple-ios${MIN_IOS} \
  -sdk "$SDK_PATH" \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -F "$BUILD/FW" \
  -framework BackBoardServices \
  -framework GraphicsServices \
  -framework SpringBoardServices \
  -framework AssertionServices \
  -framework IOKit \
  -framework UIKit \
  -framework Foundation \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework CoreFoundation \
  "${SOURCES[@]}" \
  -o "$BUILD/$APP_NAME"

echo ">> linked:"
file "$BUILD/$APP_NAME"

# ---------------------------------------------------------------- 打包 .app
APP_DIR="$BUILD/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

cp "$BUILD/$APP_NAME"        "$APP_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Info.plist"
plutil -convert binary1 "$APP_DIR/Info.plist" 2>/dev/null || plutil -convert xml1 "$APP_DIR/Info.plist"
chmod 755 "$APP_DIR/$APP_NAME"

if [ -f "$ROOT/Resources/AppIcon60x60@2x.png" ]; then
  cp "$ROOT/Resources/AppIcon60x60@2x.png" "$APP_DIR/AppIcon60x60@2x.png"
fi

# ---------------------------------------------------------------- Swift 运行时
# Swift 不是系统自带的（iOS 12.2 之后才随系统提供，但 App 仍需可用的运行时）。
# 从 SDK 里把实际用到的 dylib 拷进 .app/Frameworks 最稳，避免真机缺库闪退。
SWIFT_LIB="$SDK_PATH/usr/lib/swift"
if [ -d "$SWIFT_LIB" ]; then
  mkdir -p "$APP_DIR/Frameworks"
  # 只拷 iOS 真正需要的那几个核心库
  for lib in libswiftCore libswift_Concurrency libswift_StringProcessing \
             libswift_RegexParser libswiftos libswiftObjectiveC libswiftUIKit \
             libswiftCoreGraphics libswiftFoundation libswiftDarwin \
             libswiftCoreFoundation libswiftQuartzCore; do
    if [ -f "$SWIFT_LIB/$lib.dylib" ]; then
      cp "$SWIFT_LIB/$lib.dylib" "$APP_DIR/Frameworks/"
    fi
  done
  echo ">> swift runtime 拷入: $(ls "$APP_DIR/Frameworks" 2>/dev/null | wc -l) 个"
fi

# ---------------------------------------------------------------- 签名
# TrollStore 会用 IPA 里的 entitlements 重签；这里用 ldid 先写上
if command -v ldid >/dev/null 2>&1; then
  ldid -S"$ROOT/ent.plist" "$APP_DIR/$APP_NAME"
  echo ">> entitlements 写入完成"
  codesign -d --entitlements - "$APP_DIR/$APP_NAME" 2>&1 | head -8 || true
else
  echo "!! 警告: 未找到 ldid，产物将不带 entitlements（无法浮在其他 App 上）"
fi

# ---------------------------------------------------------------- 校验
echo ">> load commands:"
otool -L "$APP_DIR/$APP_NAME" | head -25 || true

# ---------------------------------------------------------------- 打包 IPA
cd "$BUILD"
rm -f "$OUT_IPA"
zip -qr "$OUT_IPA" Payload
cd "$ROOT"

echo ">> OK: $OUT_IPA"
ls -lh "$OUT_IPA"
