// اختبارات ZipService.
//
// ملفات ZIP تُبنى هنا بكاتب بسيط (entries مخزَّنة بلا ضغط) بدل ZipEncoder:
// اختبارات Zip Slip والـ CRC والأوضاع تحتاج تحكمًا حرفيًا في اسم الإدخال
// وحقل CRC وبتات الصلاحيات، وبعض أسماء الاختبار (../x) قد يعدّلها المشفّر.
// فك الضغط نفسه يمرّ عبر ZipDecoder الحقيقي داخل ZipService.extract.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:github_zip_pusher/models/models.dart';
import 'package:github_zip_pusher/services/zip_service.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------- CRC-32

final List<int> _crcTable = () {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int crc32Of(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ------------------------------------------------------------ ZIP writer

const int perm644 = 420; // 0o644
const int perm755 = 493; // 0o755

class ZipEntry {
  ZipEntry._({
    required this.name,
    required this.data,
    required this.method,
    required this.uncompressedSize,
    required this.crc,
    required this.externalAttrs,
    required this.unixHost,
  });

  /// ملف عادي مخزَّن. [unix] = false يحاكي أرشيفًا من ويندوز بلا أوضاع يونكس.
  factory ZipEntry.file(
    String name,
    Object content, {
    int perm = perm644,
    bool unix = true,
    int? crc,
  }) {
    final bytes = Uint8List.fromList(
      content is String ? utf8.encode(content) : content as List<int>,
    );
    return ZipEntry._(
      name: name,
      data: bytes,
      method: 0,
      uncompressedSize: bytes.length,
      crc: crc ?? crc32Of(bytes),
      externalAttrs: unix ? ((0x8000 | perm) << 16) : 0x20,
      unixHost: unix,
    );
  }

  /// رابط رمزي: المحتوى هو مسار الهدف، ونوع الملف 0xA000 في الأوضاع.
  factory ZipEntry.symlink(String name, String target) {
    final bytes = Uint8List.fromList(utf8.encode(target));
    return ZipEntry._(
      name: name,
      data: bytes,
      method: 0,
      uncompressedSize: bytes.length,
      crc: crc32Of(bytes),
      externalAttrs: (0xA000 | 511) << 16, // lrwxrwxrwx
      unixHost: true,
    );
  }

  factory ZipEntry.dir(String name) {
    return ZipEntry._(
      name: name.endsWith('/') ? name : '$name/',
      data: Uint8List(0),
      method: 0,
      uncompressedSize: 0,
      crc: 0,
      externalAttrs: ((0x4000 | perm755) << 16) | 0x10,
      unixHost: true,
    );
  }

  /// بيانات جاهزة كما ستُخزَّن (مضغوطة مثلًا) مع الحجم المعلن بعد الفك.
  factory ZipEntry.raw(
    String name,
    Uint8List data, {
    required int method,
    required int uncompressedSize,
    int crc = 0,
  }) {
    return ZipEntry._(
      name: name,
      data: data,
      method: method,
      uncompressedSize: uncompressedSize,
      crc: crc,
      externalAttrs: (0x8000 | perm644) << 16,
      unixHost: true,
    );
  }

  final String name;
  final Uint8List data;
  final int method;
  final int uncompressedSize;
  final int crc;
  final int externalAttrs;
  final bool unixHost;
}

Uint8List _u16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List buildZip(List<ZipEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final offset = out.length;

    // Local file header.
    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0x0800)) // UTF-8 names
      ..add(_u16(e.method))
      ..add(_u16(0)) // time
      ..add(_u16(0x21)) // date: 1980-01-01
      ..add(_u32(e.crc))
      ..add(_u32(e.data.length))
      ..add(_u32(e.uncompressedSize))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(name)
      ..add(e.data);

    // Central directory header.
    central
      ..add(_u32(0x02014b50))
      ..add(_u16(e.unixHost ? (3 << 8) | 20 : 20)) // version made by
      ..add(_u16(20))
      ..add(_u16(0x0800))
      ..add(_u16(e.method))
      ..add(_u16(0))
      ..add(_u16(0x21))
      ..add(_u32(e.crc))
      ..add(_u32(e.data.length))
      ..add(_u32(e.uncompressedSize))
      ..add(_u16(name.length))
      ..add(_u16(0)) // extra
      ..add(_u16(0)) // comment
      ..add(_u16(0)) // disk
      ..add(_u16(0)) // internal attrs
      ..add(_u32(e.externalAttrs))
      ..add(_u32(offset))
      ..add(name);
  }
  final cdOffset = out.length;
  final cd = central.takeBytes();
  out
    ..add(cd)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(cd.length))
    ..add(_u32(cdOffset))
    ..add(_u16(0));
  return out.takeBytes();
}

class _Collector implements Sink<List<int>> {
  final BytesBuilder _b = BytesBuilder();
  @override
  void add(List<int> data) => _b.add(data);
  @override
  void close() {}
  Uint8List bytes() => _b.takeBytes();
}

/// Deflate خام (method 8) لـ [length] بايت أصفار. يصغر إلى مئات الكيلوبايت،
/// فيمكن بناء إدخال "حجمه 100 ميغابايت" دون كتابة 100 ميغابايت على القرص.
Uint8List deflateZeros(int length) {
  final collector = _Collector();
  final sink =
      const ZLibEncoder(raw: true, level: 1).startChunkedConversion(collector);
  final chunk = Uint8List(1024 * 1024);
  var left = length;
  while (left > 0) {
    final n = left < chunk.length ? left : chunk.length;
    sink.add(n == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, n));
    left -= n;
  }
  sink.close();
  return collector.bytes();
}

int _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var j = 0;
    while (j < needle.length && haystack[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) return i;
  }
  return -1;
}

// ------------------------------------------------------------------ tests

void main() {
  late Directory tmp;
  late Directory workRoot;
  late ZipService service;

  String zipPath() => p.join(tmp.path, 'in.zip');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zip_service_test_');
    workRoot = Directory(p.join(tmp.path, 'work'))..createSync();
    service = ZipService(tempDirProvider: () async => workRoot);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ZipExtractionResult> extractEntries(
    List<ZipEntry> entries, {
    void Function(int, int)? onProgress,
  }) {
    File(zipPath()).writeAsBytesSync(buildZip(entries));
    return service.extract(zipPath(), onProgress: onProgress);
  }

  List<String> paths(ZipExtractionResult r, {bool strip = false}) =>
      r.filesFor(stripWrapper: strip).map((f) => f.relativePath).toList()
        ..sort();

  Map<String, bool> execMap(ZipExtractionResult r) =>
      {for (final f in r.entries) f.relativePath: f.executable};

  String readFile(ExtractedFile f) => File(f.absPath).readAsStringSync();

  /// الفشل يجب أن يكون ZipFailure ولا يترك مجلد عمل نصف مفكوك.
  Future<void> expectFailure(
    Future<ZipExtractionResult> future, {
    String? messageContains,
  }) async {
    await expectLater(
      future,
      throwsA(
        isA<ZipFailure>().having(
          (e) => e.message,
          'message',
          messageContains == null ? isNotEmpty : contains(messageContains),
        ),
      ),
    );
    expect(workRoot.listSync(), isEmpty, reason: 'مجلد العمل لم يُنظَّف');
  }

  // ------------------------------------------------------------ happy path

  group('الفك الأساسي', () {
    test('يفك الملفات إلى القرص ويحسب الحجم ثم يحذف المجلد عند cleanup', () async {
      final result = await extractEntries([
        ZipEntry.file('a.txt', 'hello'),
        ZipEntry.file('dir/b.txt', 'world!'),
        ZipEntry.dir('empty_dir/'),
      ]);

      expect(paths(result), ['a.txt', 'dir/b.txt']);
      expect(result.totalBytes, 11);
      expect(result.skipped, isEmpty);
      final byPath = {for (final f in result.entries) f.relativePath: f};
      expect(readFile(byPath['a.txt']!), 'hello');
      expect(readFile(byPath['dir/b.txt']!), 'world!');
      expect(byPath['a.txt']!.size, 5);
      expect(result.rootDir.existsSync(), isTrue);
      expect(p.isWithin(workRoot.path, result.rootDir.path), isTrue);

      await result.cleanup();
      expect(result.rootDir.existsSync(), isFalse);
    });

    test('الملف الفارغ داخل الأرشيف يُفك بحجم صفر', () async {
      final result = await extractEntries([
        ZipEntry.file('pkg/__init__.py', ''),
        ZipEntry.file('pkg/mod.py', 'x = 1\n'),
      ]);

      final empty =
          result.entries.firstWhere((f) => f.relativePath == 'pkg/__init__.py');
      expect(empty.size, 0);
      expect(File(empty.absPath).existsSync(), isTrue);
      expect(File(empty.absPath).lengthSync(), 0);
    });

    test('يرسل التقدم: يبدأ من (0, N) وينتهي بـ (N, N)', () async {
      const count = 25;
      final events = <List<int>>[];
      await extractEntries(
        [for (var i = 0; i < count; i++) ZipEntry.file('f$i.txt', 'x$i')],
        onProgress: (done, total) => events.add([done, total]),
      );

      expect(events, isNotEmpty);
      expect(events.first, [0, count]);
      expect(events.last, [count, count]);
      expect(events.every((e) => e[1] == count), isTrue);
      for (var i = 1; i < events.length; i++) {
        expect(events[i][0], greaterThanOrEqualTo(events[i - 1][0]));
      }
    });
  });

  // -------------------------------------------------------------- Zip Slip

  group('Zip Slip والمسارات غير الآمنة', () {
    test('../x و/abs و a/../../b تُتجاهل بـ badPath ولا يُكتب شيء خارج مجلد العمل',
        () async {
      final result = await extractEntries([
        ZipEntry.file('ok.txt', 'ok'),
        ZipEntry.file('../x', 'evil'),
        ZipEntry.file('/abs', 'evil'),
        ZipEntry.file('/abs/dir/evil.txt', 'evil'),
        ZipEntry.file('a/../../b', 'evil'),
        ZipEntry.file('C:/win/evil.txt', 'evil'),
        ZipEntry.file(r'..\winslip.txt', 'evil'),
      ]);

      expect(paths(result), ['ok.txt']);
      expect(result.skipped, hasLength(6));
      expect(result.skipped.every((s) => s.kind == SkipKind.badPath), isTrue);
      expect(result.skippedCount(SkipKind.badPath), 6);

      final skippedPaths = result.skipped.map((s) => s.path).toSet();
      expect(skippedPaths, containsAll(['../x', '/abs', 'a/../../b']));
      final slip = result.skipped.firstWhere((s) => s.path == '../x');
      expect(slip.reason, contains('Zip Slip'));

      // لا ملف خارج مجلد الاستخراج (باستثناء الـ ZIP نفسه).
      final outside = tmp
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .where(
            (path) => path != zipPath() && !p.isWithin(result.rootDir.path, path),
          );
      expect(outside, isEmpty);
      expect(
        tmp.listSync().map((e) => p.basename(e.path)).toSet(),
        {'in.zip', 'work'},
      );
      expect(workRoot.listSync(), hasLength(1)); // مجلد الاستخراج فقط
      expect(File(p.join(workRoot.path, 'x')).existsSync(), isFalse);
      expect(File(p.join(workRoot.path, 'b')).existsSync(), isFalse);
    });

    test('أرشيف كل مساراته سيئة يفشل برسالة "لا يحتوي على ملفات قابلة للرفع"',
        () async {
      await expectFailure(
        extractEntries([
          ZipEntry.file('../x', 'evil'),
          ZipEntry.file('/abs', 'evil'),
        ]),
        messageContains: 'لا يحتوي على ملفات قابلة للرفع',
      );
    });

    test('المسار المكرر: تُؤخذ النسخة الأولى وتُسجَّل الثانية badPath', () async {
      final result = await extractEntries([
        ZipEntry.file('./dup.txt', 'first'),
        ZipEntry.file('dup.txt', 'second'),
      ]);

      expect(paths(result), ['dup.txt']);
      expect(readFile(result.entries.single), 'first');
      expect(result.skippedCount(SkipKind.badPath), 1);
      expect(result.skipped.single.reason, contains('مكرر'));
    });
  });

  // ---------------------------------------------------------- common root

  group('الجذر المشترك', () {
    test('مجلد واحد يُزال', () async {
      final result = await extractEntries([
        ZipEntry.file('proj/a.txt', 'a'),
        ZipEntry.file('proj/src/b.dart', 'b'),
      ]);

      expect(result.wrapperFolder, 'proj');
      expect(paths(result), ['proj/a.txt', 'proj/src/b.dart']);
      expect(paths(result, strip: true), ['a.txt', 'src/b.dart']);
    });

    test('مجلدان متداخلان: يُزال مستوى واحد فقط ويبقى src/', () async {
      final result = await extractEntries([
        ZipEntry.file('app/src/a.dart', 'a'),
        ZipEntry.file('app/src/b.dart', 'b'),
      ]);

      expect(result.wrapperFolder, 'app');
      expect(paths(result, strip: true), ['src/a.dart', 'src/b.dart']);
    });

    test('ملفات في الجذر: لا إزالة', () async {
      final result = await extractEntries([
        ZipEntry.file('README.md', 'r'),
        ZipEntry.file('proj/a.txt', 'a'),
      ]);

      expect(result.wrapperFolder, isNull);
      expect(paths(result, strip: true), ['README.md', 'proj/a.txt']);
    });

    test('مجلدان علويان: لا إزالة', () async {
      final result = await extractEntries([
        ZipEntry.file('a/x.txt', 'x'),
        ZipEntry.file('b/y.txt', 'y'),
      ]);

      expect(result.wrapperFolder, isNull);
      expect(paths(result, strip: true), ['a/x.txt', 'b/y.txt']);
    });

    test('إزالة الجذر تحافظ على صلاحية التنفيذ وعلى المسار على القرص', () async {
      final result = await extractEntries([
        ZipEntry.file('proj/gradlew', '#!/bin/sh\n', perm: perm644),
        ZipEntry.file('proj/a.txt', 'a'),
      ]);

      final stripped = result.filesFor(stripWrapper: true);
      final gradlew = stripped.firstWhere((f) => f.relativePath == 'gradlew');
      expect(gradlew.executable, isTrue);
      expect(File(gradlew.absPath).existsSync(), isTrue);
      expect(gradlew.absPath, contains('proj'));
    });

    test('__MACOSX و.DS_Store وThumbs.db تُهمَل بصمت ولا تمنع إزالة الجذر',
        () async {
      final result = await extractEntries([
        ZipEntry.file('proj/a.txt', 'a'),
        ZipEntry.file('__MACOSX/proj/._a.txt', 'junk'),
        ZipEntry.file('proj/.DS_Store', 'junk'),
        ZipEntry.file('proj/sub/Thumbs.db', 'junk'),
        ZipEntry.file('proj/sub/desktop.ini', 'junk'),
      ]);

      expect(paths(result), ['proj/a.txt']);
      expect(result.wrapperFolder, 'proj');
      expect(result.skipped, isEmpty);
    });

    test('المسارات التي تبدأ بـ ./ تُقبل وتُوحَّد', () async {
      final result = await extractEntries([
        ZipEntry.file('./a.txt', 'a'),
        ZipEntry.file('./src/b.txt', 'b'),
        ZipEntry.file('docs/./guide.md', 'g'),
      ]);

      expect(paths(result), ['a.txt', 'docs/guide.md', 'src/b.txt']);
      expect(result.skipped, isEmpty);
    });

    test('./proj/... يُعامَل كجذر مشترك', () async {
      final result = await extractEntries([
        ZipEntry.file('./proj/a.txt', 'a'),
        ZipEntry.file('./proj/b.txt', 'b'),
      ]);

      expect(result.wrapperFolder, 'proj');
      expect(paths(result, strip: true), ['a.txt', 'b.txt']);
    });

    test(r'الباكسلاش \ يتحول إلى /', () async {
      final result = await extractEntries([
        ZipEntry.file(r'proj\src\a.txt', 'a'),
        ZipEntry.file(r'proj\b.txt', 'b'),
      ]);

      expect(paths(result), ['proj/b.txt', 'proj/src/a.txt']);
      expect(result.wrapperFolder, 'proj');
      final a = result.entries.firstWhere((f) => f.relativePath.endsWith('a.txt'));
      expect(readFile(a), 'a');
    });

    test('ZipService.wrapperFolderOf مباشرة', () {
      expect(ZipService.wrapperFolderOf(const []), isNull);
      expect(ZipService.wrapperFolderOf(const ['a/b', 'a/c']), 'a');
      expect(ZipService.wrapperFolderOf(const ['a/b/c', 'a/b/d']), 'a');
      expect(ZipService.wrapperFolderOf(const ['a/x']), 'a');
      expect(ZipService.wrapperFolderOf(const ['a']), isNull);
      expect(ZipService.wrapperFolderOf(const ['a', 'b/c']), isNull);
      expect(ZipService.wrapperFolderOf(const ['a/b', 'c/d']), isNull);
    });
  });

  // ------------------------------------------------------------------ .git

  group('بيانات .git', () {
    test('سطر واحد لكل مجلد .git مع عدد ملفاته، وتبقى .gitignore و.github',
        () async {
      final result = await extractEntries([
        ZipEntry.file('proj/main.dart', 'void main() {}'),
        ZipEntry.file('proj/.gitignore', 'build/'),
        ZipEntry.file('proj/.gitattributes', '* text=auto'),
        ZipEntry.file('proj/.github/workflows/ci.yml', 'name: ci'),
        ZipEntry.file('proj/.git/config', '[core]'),
        ZipEntry.file('proj/.git/HEAD', 'ref: refs/heads/main'),
        ZipEntry.file('proj/.git/objects/ab/cdef', 'blob'),
        ZipEntry.file('proj/vendor/lib/.git/config', '[core]'),
        ZipEntry.file('proj/tools/.GIT/index', 'idx'),
      ]);

      expect(paths(result), [
        'proj/.gitattributes',
        'proj/.github/workflows/ci.yml',
        'proj/.gitignore',
        'proj/main.dart',
      ]);

      final git = result.skipped.where((s) => s.kind == SkipKind.gitData);
      expect(git, hasLength(3));
      expect(result.skippedCount(SkipKind.gitData), 3);
      expect(result.skipped, hasLength(3));
      final byPath = {for (final s in git) s.path: s};
      expect(
        byPath.keys.toSet(),
        {'proj/.git/', 'proj/vendor/lib/.git/', 'proj/tools/.GIT/'},
      );
      expect(byPath['proj/.git/']!.reason, contains('(3 ملف)'));
      expect(byPath['proj/vendor/lib/.git/']!.reason, contains('(1 ملف)'));
    });

    test('أرشيف فيه .git فقط يفشل بلا ملفات قابلة للرفع', () async {
      await expectFailure(
        extractEntries([
          ZipEntry.file('.git/config', '[core]'),
          ZipEntry.file('.git/HEAD', 'ref'),
        ]),
        messageContains: 'لا يحتوي على ملفات قابلة للرفع',
      );
    });

    test('أرشيف فيه مجلدات ومهملات فقط يفشل بلا ملفات قابلة للرفع', () async {
      await expectFailure(
        extractEntries([
          ZipEntry.dir('a/'),
          ZipEntry.dir('b/c/'),
          ZipEntry.file('__MACOSX/._x', 'junk'),
          ZipEntry.file('.DS_Store', 'junk'),
        ]),
        messageContains: 'لا يحتوي على ملفات قابلة للرفع',
      );
    });
  });

  // ---------------------------------------------------------------- limits

  group('الحدود', () {
    test('ملف أكبر من maxFileBytes يُتجاهل بـ fileTooBig ويُفك الباقي', () async {
      final big = deflateZeros(ZipLimits.maxFileBytes + 1);
      final result = await extractEntries([
        ZipEntry.file('small.txt', 'small'),
        ZipEntry.raw(
          'big.bin',
          big,
          method: 8,
          uncompressedSize: ZipLimits.maxFileBytes + 1,
        ),
      ]);

      expect(paths(result), ['small.txt']);
      expect(result.skipped, hasLength(1));
      final s = result.skipped.single;
      expect(s.kind, SkipKind.fileTooBig);
      expect(s.path, 'big.bin');
      expect(s.reason, contains('ميغابايت'));
      expect(s.reason, contains('يتجاوز الحد'));
      expect(File(p.join(result.rootDir.path, 'big.bin')).existsSync(), isFalse);
    });

    test('أرشيف ملفه الوحيد أكبر من الحد يفشل بلا ملفات قابلة للرفع', () async {
      final big = deflateZeros(ZipLimits.maxFileBytes + 1);
      await expectFailure(
        extractEntries([
          ZipEntry.raw(
            'big.bin',
            big,
            method: 8,
            uncompressedSize: ZipLimits.maxFileBytes + 1,
          ),
        ]),
        messageContains: 'لا يحتوي على ملفات قابلة للرفع',
      );
    });

    test('تجاوز maxFiles: الزائد يُتجاهل بـ fileCountLimit ملفًا ملفًا', () async {
      const extra = 3;
      final names = [
        for (var i = 0; i < ZipLimits.maxFiles + extra; i++)
          'f${i.toString().padLeft(5, '0')}.txt',
      ];
      final result = await extractEntries([
        for (final n in names) ZipEntry.file(n, 'x'),
      ]);

      expect(result.entries, hasLength(ZipLimits.maxFiles));
      expect(result.totalBytes, ZipLimits.maxFiles);
      expect(result.skippedCount(SkipKind.fileCountLimit), extra);
      expect(
        result.skipped.map((s) => s.path).toSet(),
        names.sublist(ZipLimits.maxFiles).toSet(),
      );
      expect(
        result.skipped.first.reason,
        contains('تجاوز حد عدد الملفات (${ZipLimits.maxFiles})'),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('الملفات الزائدة عن maxFiles لا تُحسب من ميزانية الحجم', () async {
      // 6000 ملفًا صغيرًا ثم 6 ملفات بحجم 100MB معلن لكل منها: لو حُسب حجم
      // الزائدة لبلغ المجموع 600MB وفشل الأرشيف.
      final big = deflateZeros(ZipLimits.maxFileBytes);
      final result = await extractEntries([
        for (var i = 0; i < ZipLimits.maxFiles; i++)
          ZipEntry.file('f${i.toString().padLeft(5, '0')}.txt', 'x'),
        for (var i = 0; i < 6; i++)
          ZipEntry.raw(
            'big$i.bin',
            big,
            method: 8,
            uncompressedSize: ZipLimits.maxFileBytes,
          ),
      ]);

      expect(result.entries, hasLength(ZipLimits.maxFiles));
      expect(result.skippedCount(SkipKind.fileCountLimit), 6);
      expect(result.skippedCount(SkipKind.fileTooBig), 0);
      expect(result.totalBytes, ZipLimits.maxFiles);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('تجاوز maxTotalBytes يفشل برسالة الحجم الكلي ولا يترك ملفات', () async {
      // ستة ملفات حجم كل منها المعلن 100MB (= الحد المسموح للملف الواحد)،
      // أي 600MB مقابل حد كلي 500MB. الفشل يحدث من الأحجام المعلنة قبل أي كتابة.
      final big = deflateZeros(ZipLimits.maxFileBytes);
      await expectFailure(
        extractEntries([
          for (var i = 0; i < 6; i++)
            ZipEntry.raw(
              'big$i.bin',
              big,
              method: 8,
              uncompressedSize: ZipLimits.maxFileBytes,
            ),
        ]),
        messageContains:
            'يتجاوز ${ZipLimits.maxTotalBytes ~/ (1024 * 1024)} ميغابايت',
      );
    });
  });

  // ---------------------------------------------------------- bad archives

  group('أرشيفات تالفة أو غير صالحة', () {
    test('ملف فارغ (0 بايت) ← ZipFailure', () async {
      File(zipPath()).writeAsBytesSync(Uint8List(0));
      await expectFailure(service.extract(zipPath()));
    });

    test('ملف ليس ZIP أصلًا ← ZipFailure', () async {
      File(zipPath()).writeAsStringSync('this is definitely not a zip file');
      await expectFailure(service.extract(zipPath()));
    });

    test('ZIP مقطوع من نهايته (بلا سجل الدليل المركزي) ← ZipFailure', () async {
      final good = buildZip([
        ZipEntry.file('a.txt', 'aaaa'),
        ZipEntry.file('b.txt', 'bbbb'),
      ]);
      File(zipPath()).writeAsBytesSync(good.sublist(0, good.length - 40));
      await expectFailure(service.extract(zipPath()));
    });

    test('ملف غير موجود ← ZipFailure', () async {
      await expectFailure(service.extract(p.join(tmp.path, 'missing.zip')));
    });

    test('أرشيف سليم بلا أي إدخال ← ZipFailure', () async {
      await expectFailure(extractEntries(const []));
    });

    test('إدخال ببيانات ضغط تالفة ← ZipFailure ويُنظَّف مجلد العمل', () async {
      // 0xFF: BFINAL=1 وBTYPE=3 (نوع كتلة محجوز غير صالح في deflate).
      final garbage = Uint8List.fromList(List<int>.filled(32, 0xFF));
      await expectFailure(
        extractEntries([
          ZipEntry.file('good.txt', 'good'),
          ZipEntry.raw(
            'broken.bin',
            garbage,
            method: 8,
            uncompressedSize: 64,
            crc: 0x12345678,
          ),
        ]),
      );
    });
  });

  // ------------------------------------------------------------------- CRC

  group('فحص CRC', () {
    test('CRC معدَّل في ترويسة الأرشيف يفشل برسالة تذكر الملف', () async {
      await expectFailure(
        extractEntries([
          ZipEntry.file('good.txt', 'hello'),
          ZipEntry.file('docs/bad.txt', 'world', crc: crc32Of(utf8.encode('world')) ^ 0xFFFF),
        ]),
        messageContains: 'فشل فحص CRC',
      );
    });

    test('الرسالة تحمل مسار الملف التالف', () async {
      await expectLater(
        extractEntries([
          ZipEntry.file('docs/bad.txt', 'world', crc: 0xDEADBEEF),
        ]),
        throwsA(
          isA<ZipFailure>().having((e) => e.message, 'message', contains('docs/bad.txt')),
        ),
      );
    });

    test('بايت واحد تالف في المحتوى مع بقاء CRC الأصلي يفشل', () async {
      final bytes = buildZip([
        ZipEntry.file('ok.txt', 'fine'),
        ZipEntry.file('data.txt', 'payload-123456'),
      ]);
      final at = _indexOf(bytes, utf8.encode('payload-123456'));
      expect(at, greaterThan(0), reason: 'خطأ في الاختبار: المحتوى غير موجود');
      bytes[at + 3] ^= 0xFF;
      File(zipPath()).writeAsBytesSync(bytes);

      await expectFailure(
        service.extract(zipPath()),
        messageContains: 'فشل فحص CRC',
      );
    });

    test('أرشيف سليم الـ CRC يمرّ', () async {
      final result = await extractEntries([
        ZipEntry.file('a.txt', 'alpha'),
        ZipEntry.file('b.txt', 'beta' * 1000),
      ]);
      expect(result.entries, hasLength(2));
    });
  });

  // -------------------------------------------------------------- symlinks

  group('الروابط الرمزية', () {
    test('لا تُفك على القرص ولا تدخل قائمة الرفع', () async {
      final result = await extractEntries([
        ZipEntry.file('real.txt', 'real'),
        ZipEntry.symlink('link.txt', 'real.txt'),
        ZipEntry.symlink('evil', '../../etc/passwd'),
      ]);

      expect(paths(result), ['real.txt']);
      for (final name in ['link.txt', 'evil']) {
        expect(
          FileSystemEntity.typeSync(
            p.join(result.rootDir.path, name),
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
          reason: '$name كُتب على القرص',
        );
      }
    });

    test('تُسجَّل في skipped بنوع symlink', () async {
      final result = await extractEntries([
        ZipEntry.file('real.txt', 'real'),
        ZipEntry.symlink('link.txt', 'real.txt'),
      ]);

      expect(result.skippedCount(SkipKind.symlink), 1);
      expect(result.skipped.single.path, 'link.txt');
    });
  });

  // ---------------------------------------------------------- executables

  group('صلاحية التنفيذ', () {
    test('أرشيف بلا أوضاع يونكس (ويندوز): gradlew وmvnw و.sh بـ shebang تنفيذية',
        () async {
      final result = await extractEntries([
        ZipEntry.file('gradlew', 'plain text, no shebang', unix: false),
        ZipEntry.file('mvnw', '#!/bin/sh\n', unix: false),
        ZipEntry.file('scripts/build.sh', '#!/bin/bash\necho hi\n', unix: false),
        ZipEntry.file('scripts/noshebang.sh', 'echo hi\n', unix: false),
        ZipEntry.file('gradlew.bat', '@echo off', unix: false),
        ZipEntry.file('README.md', '# readme', unix: false),
      ]);

      expect(execMap(result), {
        'gradlew': true,
        'mvnw': true,
        'scripts/build.sh': true,
        'scripts/noshebang.sh': false,
        'gradlew.bat': false,
        'README.md': false,
      });
    });

    test('أوضاع يونكس موجودة لكن 644 (فُقد بت التنفيذ): السكربتات تبقى تنفيذية',
        () async {
      final result = await extractEntries([
        ZipEntry.file('gradlew', '#!/bin/sh\n', perm: perm644),
        ZipEntry.file('run.sh', '#!/bin/sh\n', perm: perm644),
        ZipEntry.file('data.json', '{}', perm: perm644),
      ]);

      expect(execMap(result), {
        'gradlew': true,
        'run.sh': true,
        'data.json': false,
      });
    });

    test('بت التنفيذ في الأرشيف يُحترم لملف ليس سكربتًا معروفًا', () async {
      final result = await extractEntries([
        ZipEntry.file('bin/tool', 'binary-ish', perm: perm755),
        ZipEntry.file('bin/data.json', '{}', perm: perm644),
        ZipEntry.file('bin/other', 'x', perm: perm644),
      ]);

      expect(execMap(result), {
        'bin/tool': true,
        'bin/data.json': false,
        'bin/other': false,
      });
    });

    test('"كل الملفات تنفيذية" (5 فأكثر) أوضاع غير موثوقة: السكربتات المعروفة فقط',
        () async {
      final result = await extractEntries([
        ZipEntry.file('gradlew', '#!/bin/sh\n', perm: perm755),
        ZipEntry.file('run.sh', '#!/bin/sh\n', perm: perm755),
        ZipEntry.file('data.json', '{}', perm: perm755),
        ZipEntry.file('README.md', '# r', perm: perm755),
        ZipEntry.file('tool', 'x', perm: perm755),
      ]);

      expect(execMap(result), {
        'gradlew': true,
        'run.sh': true,
        'data.json': false,
        'README.md': false,
        'tool': false,
      });
    });

    test('أقل من 5 ملفات كلها تنفيذية: الأوضاع موثوقة وتبقى كما هي', () async {
      final result = await extractEntries([
        ZipEntry.file('gradlew', '#!/bin/sh\n', perm: perm755),
        ZipEntry.file('data.json', '{}', perm: perm755),
        ZipEntry.file('README.md', '# r', perm: perm755),
        ZipEntry.file('tool', 'x', perm: perm755),
      ]);

      expect(execMap(result).values.every((e) => e), isTrue);
    });

    test('5 ملفات بينها واحد غير تنفيذي: الأوضاع موثوقة', () async {
      final result = await extractEntries([
        ZipEntry.file('a', 'x', perm: perm755),
        ZipEntry.file('b', 'x', perm: perm755),
        ZipEntry.file('c', 'x', perm: perm755),
        ZipEntry.file('d', 'x', perm: perm755),
        ZipEntry.file('plain.txt', 'x', perm: perm644),
      ]);

      expect(execMap(result), {
        'a': true,
        'b': true,
        'c': true,
        'd': true,
        'plain.txt': false,
      });
    });
  });
}
