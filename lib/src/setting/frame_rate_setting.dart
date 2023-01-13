import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:get/get.dart';

import '../utils/log.dart';

class FrameRateSetting {
  static Future<void> init() async {
    if (!GetPlatform.isIOS) {
      return;
    }
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } on PlatformException catch (e) {
      Log.error('init FrameRateSetting failed', e);
      Log.upload(e);
    }
    Log.debug('init FrameRateSetting success');
  }
}
