import 'dart:io';

const String _binKey = 'BIN';
const String _tmpKey = 'TMP';
const String _homeKey = 'HOME';
const String _configKey = 'CONFIG';
const String _filesKey = 'FILES';
const String _usrKey = 'USR';
const String _dataKey = 'DATA';
const String _pathKey = 'PATH';

class RuntimeEnvir {
  static bool _isInit = false;
  static Map<String, dynamic> _environment = {};
  static Map<String, dynamic> get environment => _environment;

  static String _packageName = '';
  static String get packageName => _packageName;

  static void initEnvirFromMap(Map<String, dynamic> map) {
    _environment = Map<String, dynamic>.from(map);
    _isInit = true;
  }

  static void initEnvirWithPackageName(String packageName) {
    if (_isInit) {
      return;
    }
    _packageName = packageName;
    final dataDir = '/data/data/$packageName';
    final filesDir = '$dataDir/files';
    Directory(filesDir).createSync(recursive: true);

    final usrDir = '$filesDir/usr';
    final binDir = '$usrDir/bin';
    final homeDir = '$filesDir/home';
    final tmpDir = '$usrDir/tmp';

    _environment[_dataKey] = dataDir;
    _environment[_filesKey] = filesDir;
    _environment[_configKey] = filesDir;
    _environment[_usrKey] = usrDir;
    _environment[_binKey] = binDir;
    _environment[_homeKey] = homeDir;
    _environment[_tmpKey] = tmpDir;
    _environment[_pathKey] = '$binDir:${Platform.environment['PATH'] ?? ''}';
    _isInit = true;
  }

  static Map<String, String> envir() {
    final map = Map<String, String>.from(Platform.environment);
    map['PATH'] = path;
    return map;
  }

  static void put(String key, dynamic value) {
    _environment[key] = value;
  }

  static dynamic get(String key) => _environment[key] ?? '';

  static String _require(String key) {
    final val = _environment[key];
    if (val == null) {
      throw StateError('RuntimeEnvir key "$key" is not initialized');
    }
    return val.toString();
  }

  static String get binPath => _require(_binKey);
  static set binPath(String? value) => _environment[_binKey] = value;

  static String get path => _require(_pathKey);

  static String get dataPath => _require(_dataKey);

  static String get configPath => _require(_configKey);

  static String get usrPath => _require(_usrKey);
  static set usrPath(String? value) => _environment[_usrKey] = value;

  static String get tmpPath => _require(_tmpKey);
  static set tmpPath(String? value) => _environment[_tmpKey] = value;

  static String get homePath => _require(_homeKey);
  static set homePath(String? value) => _environment[_homeKey] = value;

  static String get filesPath => _require(_filesKey);
  static set filesPath(String? value) => _environment[_filesKey] = value;
}
