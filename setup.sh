#!/usr/bin/env bash
# يولّد مجلد android/ ويضبط الصلاحيات ثم يجلب الحزم.
set -e
cd "$(dirname "$0")"

flutter create --org com.example --project-name github_zip_pusher --platforms android .
rm -f test/widget_test.dart

MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MANIFEST"
fi

# flutter_secure_storage يحتاج minSdk 23 على الأقل
for f in android/app/build.gradle android/app/build.gradle.kts; do
  [ -f "$f" ] && sed -i -E 's/minSdk(Version)? ?=? ?flutter\.minSdkVersion/minSdk = 23/; s/minSdkVersion flutter\.minSdkVersion/minSdkVersion 23/' "$f"
done

flutter pub get
echo "تم. للبناء: flutter build apk --release"
