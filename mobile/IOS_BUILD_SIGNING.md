# iOS 环境恢复、编译、签名、真机安装流程

本文档记录本项目在 macOS 上已验证通过的 iOS 构建流程，适用于下次恢复环境后直接编译、签名、安装到真机验证。

## 当前已验证配置

| 项目 | 值 |
| --- | --- |
| 后端服务地址 | `http://192.168.15.122:4123/` |
| Team ID | `BFH7K2ZV3V` |
| Bundle ID | `app.garnet7876.monkey2279` |
| Provisioning Profile Specifier | `00008120-0014182C1193C01EFPY5TY` |
| 签名证书 | `iPhone Distribution: Saiden Fernando (BFH7K2ZV3V)` |
| P12 目录 | `P12/` |
| 外置盘 platform 备份目录 | `/Volumes/SSD_APPS/XcodePlatforms` |

注意：`P12/` 包含证书、描述文件和密码文件，不能提交到 Git。

## 1. 恢复 Xcode iOS platform

如果系统盘空间不足，Xcode platform 可以先下载到外置盘，再从外置盘导入。

已保存的外置盘文件：

```bash
/Volumes/SSD_APPS/XcodePlatforms/iphonesimulator_18.3.1_22D8075.dmg
```

恢复命令：

```bash
xcodebuild -importPlatform /Volumes/SSD_APPS/XcodePlatforms/iphonesimulator_18.3.1_22D8075.dmg
```

如果外置盘没有可用备份，重新下载到外置盘：

```bash
mkdir -p /Volumes/SSD_APPS/XcodePlatforms
xcodebuild -downloadPlatform iOS -exportPath /Volumes/SSD_APPS/XcodePlatforms
```

曾尝试指定 `22C146`：

```bash
xcodebuild -downloadPlatform iOS -exportPath /Volumes/SSD_APPS/XcodePlatforms -buildVersion 22C146
```

该版本返回 `iOS 22C146 is not available for download.`，后续优先使用不指定 `-buildVersion` 的下载方式。

## 2. 导入 P12 证书

macOS 的 `security import` 对当前 P12 的 PBES2/AES/SHA256 封装不兼容，需要先用 OpenSSL 重新封装成 legacy P12。

```bash
CERT_PASS="$(cat P12/密码.txt)"

openssl pkcs12 \
  -in P12/证书文件.p12 \
  -nodes \
  -passin "pass:${CERT_PASS}" \
  -out /tmp/agent_dock_mobile_cert.pem

openssl pkcs12 \
  -export \
  -legacy \
  -in /tmp/agent_dock_mobile_cert.pem \
  -out /tmp/agent_dock_mobile_legacy.p12 \
  -passout "pass:${CERT_PASS}"

security import /tmp/agent_dock_mobile_legacy.p12 \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "${CERT_PASS}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
```

导入 Apple WWDR G3 中间证书，否则可能出现 `security find-identity` 找不到可用签名身份：

```bash
curl -L https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer \
  -o /tmp/AppleWWDRCAG3.cer

security add-certificates \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  /tmp/AppleWWDRCAG3.cer

security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db"
```

期望能看到类似：

```text
iPhone Distribution: Saiden Fernando (BFH7K2ZV3V)
```

## 3. 安装描述文件

```bash
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"

ditto P12/描述文件.mobileprovision \
  "$HOME/Library/MobileDevice/Provisioning Profiles/b2622795-297a-4bd8-a289-3d0cb533ef9d.mobileprovision"
```

## 4. 确认项目配置

后端地址应为：

```text
http://192.168.15.122:4123/
```

当前相关文件：

```text
lib/main.dart
lib/src/features/launch/launch_page.dart
ios/Runner/Info.plist
ios/Runner.xcodeproj/project.pbxproj
```

关键配置应包含：

```text
PRODUCT_BUNDLE_IDENTIFIER = app.garnet7876.monkey2279
DEVELOPMENT_TEAM = BFH7K2ZV3V
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = iPhone Distribution
PROVISIONING_PROFILE_SPECIFIER = 00008120-0014182C1193C01EFPY5TY
```

`ios/Runner/Info.plist` 需要允许访问局域网 HTTP 后端：

```text
NSAppTransportSecurity exception for 192.168.15.122
NSLocalNetworkUsageDescription
```

## 5. Archive 编译

```bash
xcodebuild archive \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/ios/archive/Runner.xcarchive \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=BFH7K2ZV3V \
  PRODUCT_BUNDLE_IDENTIFIER=app.garnet7876.monkey2279 \
  CODE_SIGN_IDENTITY='iPhone Distribution'
```

成功后会生成：

```text
build/ios/archive/Runner.xcarchive
```

## 6. 导出 IPA

先准备导出配置：

```bash
cat > /tmp/agent_dock_export_options.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>release-testing</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>teamID</key>
	<string>BFH7K2ZV3V</string>
	<key>signingCertificate</key>
	<string>iOS Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>app.garnet7876.monkey2279</key>
		<string>00008120-0014182C1193C01EFPY5TY</string>
	</dict>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
</dict>
</plist>
EOF
```

导出：

```bash
xcodebuild -exportArchive \
  -archivePath build/ios/archive/Runner.xcarchive \
  -exportPath build/ios/ipa \
  -exportOptionsPlist /tmp/agent_dock_export_options.plist
```

成功后会生成：

```text
build/ios/ipa/agent_dock_mobile.ipa
```

## 7. 安装到真机并启动验证

查看连接设备：

```bash
xcrun devicectl list devices
```

本次验证过的设备 ID：

```text
7424F506-04DC-4B5E-85E8-1784E338D9C5
```

安装 IPA：

```bash
xcrun devicectl device install app \
  --device 7424F506-04DC-4B5E-85E8-1784E338D9C5 \
  build/ios/ipa/agent_dock_mobile.ipa
```

启动应用：

```bash
xcrun devicectl device process launch \
  --device 7424F506-04DC-4B5E-85E8-1784E338D9C5 \
  app.garnet7876.monkey2279
```

如果换了手机，需要把 `--device` 后面的 ID 替换为 `xcrun devicectl list devices` 输出中的新设备 ID。轻松签能安装只说明 IPA 签名和设备授权基本可用，命令行安装仍需要设备在线并被 Xcode 信任。

## 8. 清理临时文件

可清理本次重新封装证书产生的临时文件：

```bash
rm -f /tmp/agent_dock_mobile_cert.pem
rm -f /tmp/agent_dock_mobile_legacy.p12
rm -f /tmp/AppleWWDRCAG3.cer
rm -f /tmp/agent_dock_export_options.plist
```

不要删除外置盘的 platform 备份：

```text
/Volumes/SSD_APPS/XcodePlatforms
```

## 9. 常见问题

`security import` 失败或提示 MAC / decrypt 相关错误：
先按第 2 步用 OpenSSL `-legacy` 重新封装 P12，再导入 legacy P12。

`security find-identity` 显示 0 个可用身份：
通常是缺 Apple WWDR G3 中间证书，按第 2 步导入 `AppleWWDRCAG3.cer`。

`Any iOS Device` 不可用或提示缺 iOS platform：
按第 1 步从外置盘导入 platform，或重新下载到外置盘后导入。

指定下载 `-buildVersion 22C146` 失败：
Apple 当前没有提供该 buildVersion 下载，使用不指定 `-buildVersion` 的方式。

真机无法访问后端：
确认手机和 `192.168.15.122` 在同一局域网，后端监听 `4123`，并确认 `Info.plist` 已配置局域网访问说明和 ATS HTTP 例外。
