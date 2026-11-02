import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStore {
  const TokenStore();

  static const _key = 'github_pat';

  // الإصدار 11 أزال خيار encryptedSharedPreferences؛ الإعدادات الافتراضية
  // (AES-GCM فوق مفتاح في Android Keystore) هي الموصى بها.
  // ملاحظة ترحيل: توكن حُفظ بإصدار قديم (9.x) لا يُقرأ بعد الترقية، فيمسحه
  // read() أدناه ويُطلب من المستخدم إدخاله مرة واحدة.
  static const _storage = FlutterSecureStorage();

  /// Returns null (instead of throwing) when the stored value cannot be
  /// decrypted, e.g. "Failed to unwrap key" after an Android backup restore.
  /// The unreadable data is wiped so the user is simply asked for the token
  /// again.
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      try {
        await _storage.deleteAll();
      } catch (_) {}
      return null;
    }
  }

  Future<void> write(String token) => _storage.write(key: _key, value: token);

  /// Removes the saved token. Throws only if the storage cannot be cleared at
  /// all, so callers can tell the user the token may still be on the device.
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // A corrupted store can refuse a single delete but still be wipeable.
      await _storage.deleteAll();
    }
  }
}
