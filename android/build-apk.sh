#!/usr/bin/env bash
# Build the puddlezit Android APK (a WebView wrapper around ../index.html).
#
# Requirements (no Android Studio needed):
#   - JDK 11+ (javac, keytool)
#   - aapt, zipalign, apksigner   (Debian/Ubuntu: apt install aapt zipalign apksigner)
#   - dx jar:        https://repo1.maven.org/maven2/com/jakewharton/android/repackaged/dalvik-dx/14.0.0_r21/dalvik-dx-14.0.0_r21.jar
#   - android stub:  https://repo1.maven.org/maven2/com/google/android/android/4.1.1.4/android-4.1.1.4.jar
#   - framework jar with resources (for aapt -I), e.g. Robolectric android-all:
#     https://repo1.maven.org/maven2/org/robolectric/android-all/9-robolectric-4913185-2/android-all-9-robolectric-4913185-2.jar
#     (or a real $ANDROID_HOME/platforms/android-*/android.jar if you have the SDK)
#
# Usage: DX_JAR=... STUB_JAR=... FRAMEWORK_JAR=... ./build-apk.sh
set -euo pipefail
cd "$(dirname "$0")"

DX_JAR="${DX_JAR:?path to dalvik-dx jar}"
STUB_JAR="${STUB_JAR:?path to android stub jar}"
FRAMEWORK_JAR="${FRAMEWORK_JAR:?path to android framework jar with resources}"
KS=puddlezit.keystore
KS_PASS=puddlezit2026   # hobby key for direct installs; use a private key for Play

rm -rf obj build && mkdir -p obj build/assets
cp ../index.html build/assets/index.html

javac --release 8 -nowarn -cp "$STUB_JAR" -d obj src/com/puddlezit/app/MainActivity.java
java -cp "$DX_JAR" com.android.dx.command.Main --dex --min-sdk-version=21 --output=build/classes.dex obj

aapt package -f -M AndroidManifest.xml -S res -A build/assets -I "$FRAMEWORK_JAR" -F build/unsigned.apk
(cd build && zip -qj unsigned.apk classes.dex)

zipalign -f 4 build/unsigned.apk build/aligned.apk
apksigner sign --ks "$KS" --ks-key-alias puddlezit \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out build/puddlezit.apk build/aligned.apk
apksigner verify build/puddlezit.apk
echo "Built: build/puddlezit.apk"
