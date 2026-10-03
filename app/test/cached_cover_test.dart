import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/ui/widgets/cached_cover.dart';

void main() {
  test('a cover kept in the folder is read from it, and two asks at once share one read', () async {
    final cache = await Directory.systemTemp.createTemp('covers');
    addTearDown(() async {
      CoverFiles.useFolder(null);
      await cache.delete(recursive: true);
    });
    const url = 'https://example.invalid/kept.jpg';
    await Directory('${cache.path}/covers').create();
    File('${cache.path}/covers/${CoverFiles.fileName(url)}')
        .writeAsBytesSync([1, 2, 3]);
    CoverFiles.useFolder(cache.path);

    final both = await Future.wait([
      CoverFiles.bytes(url),
      CoverFiles.bytes(url),
    ]).timeout(const Duration(seconds: 5));
    expect(both, [
      [1, 2, 3],
      [1, 2, 3],
    ]);
    // And once more, after the first read is over
    expect(await CoverFiles.bytes(url), [1, 2, 3]);
  });

  test('different addresses get different files', () {
    expect(
      CoverFiles.fileName('https://i.ytimg.com/vi/a/hqdefault.jpg'),
      isNot(CoverFiles.fileName('https://i.ytimg.com/vi/b/hqdefault.jpg')),
    );
  });
}
