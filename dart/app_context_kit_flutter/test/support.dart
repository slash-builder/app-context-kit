import 'dart:convert';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';

/// An in-memory asset bundle: `{'app.json': '<text>'}`. Asking for anything else fails like the real one.
class MapBundle extends CachingAssetBundle {
  MapBundle(this.assets);
  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final text = assets[key];
    if (text == null) throw FlutterError('Unable to load asset: "$key".');
    final bytes = Uint8List.fromList(utf8.encode(text));
    return ByteData.view(bytes.buffer);
  }
}

const goodManifest = '{"id":"dev.test.demo","name":"Demo","version":"0.1.0"}';
