import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

Box? box;

Future<void> initSettingStore(String path) async {
  Hive.init(path);
  box ??= await Hive.openBox('setting');
}

final Map<String, ValueNotifier<dynamic>> _valueMap = {};

class Setting {
  const Setting(this.key);
  final String key;

  ValueNotifier<dynamic> get ob {
    return _valueMap.putIfAbsent(
      key,
      () => ValueNotifier<dynamic>(value),
    );
  }

  dynamic get value => get();

  set value(dynamic newValue) {
    set(newValue);
    ob.value = newValue;
  }

  dynamic get() {
    return box?.get(key, defaultValue: null);
  }

  void set(dynamic value) {
    box?.put(key, value);
  }
}

extension SettingExt on String {
  Setting get setting => Setting(this);
}
