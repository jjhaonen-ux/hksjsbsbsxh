#!/usr/bin/env bash
# يولّد مجلد android/ ويضبط الصلاحيات ثم يجلب الحزم.
#
# متغير اختياري:
#   APP_ORG   مساحة اسم الحزمة؛ معرّف التطبيق يصير "$APP_ORG.github_zip_pusher".
#             الافتراضي io.github.zippusher (com.example مرفوض في Google Play).
#             يُقرأ عند توليد android/ فقط: غيّره قبل أول تشغيل.
set -euo pipefail
cd "$(dirname "$0")"

APP_ORG="${APP_ORG:-io.github.zippusher}"
MIN_SDK=24        # flutter_secure_storage 11 يرفع الحد الأدنى إلى 24 (وهو حد Flutter نفسه منذ 3.35)
COMPILE_SDK=36    # شبكة أمان: يُرفع compileSdk للإضافات الأقدم فقط ولا يُخفَّض أبدًا

die() {
  echo "خطأ: $*" >&2
  exit 1
}

# sed -i تختلف بين GNU وmacOS (BSD)، فنكتب إلى ملف مؤقت ثم نستبدل الأصل.
# الاستخدام: sed_inplace <ملف> <وسائط sed...>
sed_inplace() {
  local file="$1"
  shift
  local tmp="$file.tmp.$$"
  sed "$@" "$file" >"$tmp"
  mv "$tmp" "$file"
}

org_re='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
[[ "$APP_ORG" =~ $org_re ]] ||
  die "APP_ORG غير صالح: \"$APP_ORG\" (مثال صحيح: io.github.myname)"

flutter create --org "$APP_ORG" --project-name github_zip_pusher --platforms android .

# اختبار القالب الافتراضي يشير إلى MyApp وسيفشل في flutter analyze.
# لا يُحذف إلا إذا كان هو نفسه، فتبقى اختباراتنا.
if [ -f test/widget_test.dart ] && grep -q 'MyApp' test/widget_test.dart; then
  rm -f test/widget_test.dart
  rmdir test 2>/dev/null || true
fi

# ---------------------------------------------------------------- Manifest
MANIFEST=android/app/src/main/AndroidManifest.xml
[ -f "$MANIFEST" ] || die "لم يُعثر على $MANIFEST"

# السطر يبقى واحدًا عمدًا: \n في نص الاستبدال لا تعمل في sed على macOS.
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed_inplace "$MANIFEST" \
    's#<application#<uses-permission android:name="android.permission.INTERNET"/><application#'
fi
grep -q 'android.permission.INTERNET' "$MANIFEST" ||
  die "تعذر إضافة صلاحية INTERNET إلى $MANIFEST"

# منع النسخ الاحتياطي التلقائي لأندرويد: مفاتيح Keystore لا تنتقل مع النسخة،
# فتفشل قراءة التوكن بعد الاستعادة ("Failed to unwrap key").
if grep -q 'android:allowBackup' "$MANIFEST"; then
  sed_inplace "$MANIFEST" -E \
    's/android:allowBackup="[^"]*"/android:allowBackup="false"/'
else
  sed_inplace "$MANIFEST" \
    's#<application#<application android:allowBackup="false"#'
fi
grep -q 'android:allowBackup="false"' "$MANIFEST" ||
  die "تعذر ضبط android:allowBackup في $MANIFEST"

# ------------------------------------------------------------------ minSdk
# نُبقي قيمة Flutter إن كانت أعلى (maxOf)، فلا نخفضها تحت ما يطلبه المحرك.
fix_min_sdk() {
  local f="$1" expr
  case "$f" in
    *.kts) expr="maxOf(flutter.minSdkVersion, $MIN_SDK)" ;;
    *) expr="Math.max(flutter.minSdkVersion, $MIN_SDK)" ;;
  esac
  sed_inplace "$f" -E \
    "s/(minSdk(Version)?)([ =]+)flutter\\.minSdkVersion/\\1\\3$expr/"
}

has_min_sdk() {
  grep -Eq \
    "(maxOf|Math\\.max)\\(flutter\\.minSdkVersion, *$MIN_SDK\\)|minSdk(Version)?[ =]+(2[3-9]|[3-9][0-9])([^0-9]|$)" \
    "$1"
}

found_gradle=0
for f in android/app/build.gradle.kts android/app/build.gradle; do
  [ -f "$f" ] || continue
  found_gradle=1
  fix_min_sdk "$f"
  has_min_sdk "$f" ||
    die "تعذر ضبط minSdk على $MIN_SDK في $f؛ عدّله يدويًا ثم أعد التشغيل."
done
[ "$found_gradle" = 1 ] || die "لم يُعثر على android/app/build.gradle(.kts)"

# -------------------------------------------------------------- compileSdk
# بعض الإضافات (مثل file_picker) تُترجَم مقابل SDK أقدم من المطلوب، فنرفع
# compileSdk لمكتبات المشروع. السكربت يعيش داخل android/ ويُستدعى من
# settings.gradle(.kts)، فلا يُلمس ~/.gradle ولا يتأثر به أي مشروع آخر.
FIX_NAME=force-compile-sdk.gradle
cat >"android/$FIX_NAME" <<GRADLE
// يولّده setup.sh — لا تعدّله يدويًا.
// يرفع compileSdk لكل مكتبة (غير app) إلى ${COMPILE_SDK} على الأقل، ولا يخفضه.
def targetSdk = ${COMPILE_SDK}

gradle.beforeProject { p ->
    if (p == p.rootProject || p.name == 'app') return
    p.afterEvaluate {
        def ext = p.extensions.findByName('android')
        if (ext == null) return
        try {
            def hasProp = ext.hasProperty('compileSdk')
            def current = hasProp ? ext.compileSdk : null
            if (current == null || current < targetSdk) {
                if (hasProp) {
                    ext.compileSdk = targetSdk
                } else {
                    ext.compileSdkVersion targetSdk
                }
            }
        } catch (Exception e) {
            p.logger.warn('force-compile-sdk: تعذر ضبط compileSdk للمكتبة ' + p.name + ': ' + e.message)
        }
    }
}
GRADLE

if [ -f android/settings.gradle.kts ]; then
  grep -q "$FIX_NAME" android/settings.gradle.kts ||
    printf '\napply(from = "%s")\n' "$FIX_NAME" >>android/settings.gradle.kts
elif [ -f android/settings.gradle ]; then
  grep -q "$FIX_NAME" android/settings.gradle ||
    printf "\napply from: '%s'\n" "$FIX_NAME" >>android/settings.gradle
else
  die "لم يُعثر على android/settings.gradle(.kts)"
fi

flutter pub get
echo "تم. معرّف التطبيق: $APP_ORG.github_zip_pusher — للبناء: flutter build apk --release"
