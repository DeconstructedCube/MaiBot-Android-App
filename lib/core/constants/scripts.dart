import '../utils/runtime_envir.dart';
import '../config/app_config.dart';

// ubuntu path (保持原有路径结构，但不再使用 proot-distro)
// ubuntu path (keep original path structure, but no longer use proot-distro)
String prootDistroPath = '${RuntimeEnvir.usrPath}/var/lib/proot-distro';
String ubuntuPath = '$prootDistroPath/installed-rootfs/ubuntu';
String ubuntuName = Config.ubuntuFileName.replaceAll(RegExp('-pd.*'), '');


