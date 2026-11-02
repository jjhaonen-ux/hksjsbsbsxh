# GitHub ZIP Pusher

تطبيق Flutter: إدخال التوكن → إنشاء مستودع → اختيار ZIP → رفعه في commit واحد عبر Git Data API.

## التشغيل
```bash
./setup.sh                 # flutter create + الصلاحيات + pub get
flutter run                # تجربة على جهاز
flutter build apk --release
```
للإصدار النهائي أعدّ توقيع التطبيق (keystore) في `android/app/build.gradle`.

## ملاحظات
- المستودع الفارغ: الـ Git Data API يرفض العمل عليه (409)، لذلك يُنشأ أول commit عبر Contents API
  (ملف `.gitkeep`) ثم يُبنى الـ commit الفعلي فوقه دون هذا الملف في الشجرة النهائية.
- إعادة المحاولة تشمل 429 و403 (حد المعدل) و5xx وأخطاء الشبكة.

## البناء عبر GitHub Actions
1. ارفع محتويات المشروع (بما فيها `.github/`) إلى مستودع على فرع `main`.
2. تبويب **Actions** → **Build APK** (يعمل تلقائيًا عند كل push، أو زر Run workflow).
3. بعد اكتماله (≈5–8 دقائق) نزّل الـ Artifact باسم `github-zip-pusher-apk` وفكّه للحصول على `app-release.apk`.

ملاحظة: الـ APK موقّع بمفتاح debug الافتراضي، يصلح للتثبيت المباشر لا للنشر على Play.
