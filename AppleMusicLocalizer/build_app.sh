#!/bin/bash

# 設定參數
APP_NAME="AppleMusicLocalizer"
BUNDLE_ID="com.andy.AppleMusicLocalizer"
VERSION="1.0.0"

echo "開始建置 ${APP_NAME} Release 版本..."
swift build -c release

# 建立 .app 目錄結構
echo "建立 .app Bundle 目錄結構..."
APP_DIR="${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# 清除舊的打包檔
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 取得編譯後的二進位執行檔路徑並複製
EXECUTABLE_PATH=$(swift build -c release --show-bin-path)/${APP_NAME}
cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/"

# 複製 App 圖示
if [ -f "Resources/AppIcon.icns" ]; then
    echo "複製 AppIcon.icns 至 Resources..."
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/"
fi

# 建立 Info.plist
# 非常重要：必須宣告 NSAppleEventsUsageDescription，否則 macOS 會直接阻擋 App 控制 Music 的行為
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Apple Music 翻譯</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>需要您的授權以讀取與還原 Apple Music 中的歌曲名稱。</string>
</dict>
</plist>
EOF

echo "打包完成！✅"
echo "應用程式已建立於：$(pwd)/${APP_DIR}"
