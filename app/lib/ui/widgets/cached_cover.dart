import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A cover from the internet kept on the phone: fetched once, then read from a file, instead of fetched again every
/// time the app starts or the memory cache lets it go. Every fetch wakes the radio and every cover that scrolls in
/// was a download; a file is neither.
@immutable
class CachedCover extends ImageProvider<CachedCover> {
  const CachedCover(this.url);

  final String url;

  @override
  Future<CachedCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedCover key, ImageDecoderCallback decode) {
    // Where fetching is made up (the tests), the picture is fetched as it always was, and no file is kept
    if (HttpOverrides.current != null) {
      return NetworkImage(url).loadImage(NetworkImage(url), decode);
    }
    return MultiFrameImageStreamCompleter(
      codec: _codec(decode),
      scale: 1,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final bytes = await CoverFiles.bytes(url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is CachedCover && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CachedCover("$url")';
}

/// The files of [CachedCover], in the app's cache folder (which the system may empty when it needs the room), kept
/// under [_limit] bytes by dropping the oldest when the app starts. Without a folder, or with one that cannot be used,
/// the files are lost, never the pictures: they are then fetched as if there were none.
abstract final class CoverFiles {
  static const _limit = 120 << 20;

  /// Covers being read or fetched, so that two sizes of one cover make one download.
  static final _pending = <String, Future<Uint8List>>{};
  static Future<Directory>? _folder;

  /// Keeps the covers in a folder inside [cache], the cache folder of the app as the native side names it.
  static void useFolder(String? cache) {
    _folder = cache == null ? null : _open(cache);
  }

  static Future<Uint8List> bytes(String url) => _pending.putIfAbsent(
    url,
    // A block, not an arrow: what `remove` gives back is this very future, which it would then wait for
    () => _read(url).whenComplete(() {
      _pending.remove(url);
    }),
  );

  static Future<Uint8List> _read(String url) async {
    Directory? folder;
    try {
      folder = await _folder;
    } on Object {
      // A folder that could not be made
    }
    if (folder == null) return _fetch(url);
    final file = File('${folder.path}/${_name(url)}');
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      // Not kept yet
    }
    final bytes = await _fetch(url);
    try {
      // Written aside and moved into place, so that a file half written is never read as a picture
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes);
      await part.rename(file.path);
    } on FileSystemException {
      // Kept another time
    }
    return bytes;
  }

  static Future<Directory> _open(String cache) async {
    final folder = await Directory('$cache/covers').create(recursive: true);
    unawaited(_trim(folder));
    return folder;
  }

  /// Drops the oldest files until the rest fit in [_limit].
  static Future<void> _trim(Directory folder) async {
    try {
      final files = <(File, FileStat)>[];
      await for (final entry in folder.list()) {
        if (entry is File) files.add((entry, await entry.stat()));
      }
      var total = files.fold<int>(0, (sum, f) => sum + f.$2.size);
      if (total <= _limit) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= _limit) break;
        await file.delete();
        total -= stat.size;
      }
    } on FileSystemException {
      // Tried again at the next start
    }
  }

  static final _client = HttpClient()..autoUncompress = false;

  static Future<Uint8List> _fetch(String url) async {
    final uri = Uri.parse(url);
    final response = await (await _client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) throw StateError('$url is an empty file');
    return bytes;
  }

  /// A file name for [url]: its 64-bit FNV-1a hash.
  @visibleForTesting
  static String fileName(String url) => _name(url);

  static String _name(String url) {
    var hash = -3750763034362895579; // 0xcbf29ce484222325
    for (final unit in url.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }
}
