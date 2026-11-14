package com.maibot.maibot_android

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcel
import android.os.ResultReceiver
import android.os.SystemClock
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.text.TextUtils
import android.view.accessibility.AccessibilityManager
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
@Suppress("DEPRECATION")
class MainActivity : FragmentActivity() {

    companion object {
        @JvmStatic
        var instance: MainActivity? = null
            private set

        private const val TAG_FLUTTER_FRAGMENT = "flutter_fragment"
        private const val ENGINE_ID = "my_engine_id"
        const val ACTION_FINISH_UI = "com.maibot.maibot_android.ACTION_FINISH_UI"
    }

    private var flutterFragment: FlutterFragment? = null
    private lateinit var mContext: Context
    private lateinit var fragmentManager: FragmentManager
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var lastProcJiffies: Long = -1L
    private var lastSampleElapsedMs: Long = -1L
    private val finishUiReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (ACTION_FINISH_UI == intent?.action && !isFinishing) {
                finishAffinity()
            }
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        instance = this
        mContext = this

        // 用户主动启动应用，重置显式停止标志
        BackendPrefs.setUserStopped(this, false)
        val filter = IntentFilter(ACTION_FINISH_UI)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(finishUiReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(finishUiReceiver, filter)
        }
        // 在 super.onCreate 之前确保 FlutterEngine 已放入 Cache 中，
        // 防止在 Activity 重建（如被 OOMKiller 回收后重新进入）时
        // FragmentManager 自动恢复 FlutterFragment 抛出 IllegalStateException
        var flutterEngine = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (flutterEngine == null) {
            flutterEngine = FlutterEngine(this.applicationContext, null, false)
            flutterEngine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            GeneratedPluginRegistrant.registerWith(flutterEngine)
            FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
        }
        setupMethodChannel(flutterEngine)

        super.onCreate(savedInstanceState)
        setContentView(R.layout.my_activity_layout)

        fragmentManager = supportFragmentManager
        flutterFragment = fragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT) as? FlutterFragment
        if (flutterFragment == null) {
            val fragment = FlutterFragment.withCachedEngine(ENGINE_ID).build<FlutterFragment>()
            flutterFragment = fragment
            fragmentManager
                .beginTransaction()
                .add(R.id.fl_container, fragment, TAG_FLUTTER_FRAGMENT)
                .commit()
        }
    }

    private fun setupMethodChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maibot_channel").setMethodCallHandler { call, result ->
            when (call.method) {
                "lib_path" -> {
                    result.success(mContext.applicationContext.applicationInfo.nativeLibraryDir)
                }
                "hide_from_recents" -> {
                    val hide = call.argument<Boolean>("hide") ?: false
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    var targetTask: ActivityManager.AppTask? = null
                    if (am != null) {
                        for (task in am.appTasks) {
                            if (task.taskInfo?.id == taskId) {
                                targetTask = task
                                break
                            }
                        }
                    }
                    if (targetTask != null) {
                        targetTask.setExcludeFromRecents(hide)
                        result.success(true)
                    } else {
                        result.error("ERROR", "Task not found", null)
                    }
                }
                "control_backend_service" -> {
                    val target = call.argument<String>("target") ?: "all"
                    val action = call.argument<String>("action") ?: "start"
                    val binPath = call.argument<String>("binPath")
                    val homePath = call.argument<String>("homePath")
                    val tmpPath = call.argument<String>("tmpPath")
                    val ubuntuPath = call.argument<String>("ubuntuPath")
                    val uvIndexUrl = call.argument<String>("uvIndexUrl")
                    val cols = call.argument<Int>("cols")
                    val rows = call.argument<Int>("rows")

                    if (action.equals("stop", ignoreCase = true) && target.equals("all", ignoreCase = true)) {
                        BackendPrefs.setUserStopped(mContext, true)
                    } else if (action.equals("start", ignoreCase = true) || action.equals("restart", ignoreCase = true)) {
                        BackendPrefs.setUserStopped(mContext, false)
                    }

                    val needsAck = action.equals("stop", ignoreCase = true) ||
                        action.equals("safe_terminate", ignoreCase = true) ||
                        action.equals("restart", ignoreCase = true)

                    val completed = AtomicBoolean(false)
                    val mainHandler = Handler(Looper.getMainLooper())
                    val ipcReceiver = if (needsAck) {
                        createIpcResultReceiver(mainHandler) {
                            if (completed.compareAndSet(false, true)) {
                                result.success(true)
                            }
                        }
                    } else {
                        null
                    }

                    val intent = Intent(mContext, ProotService::class.java).apply {
                        if (action.equals("stop", ignoreCase = true) && target.equals("all", ignoreCase = true)) {
                            this.action = "STOP"
                        } else {
                            this.action = "CONTROL"
                            putExtra("target", target)
                            putExtra("action", action)
                        }
                        putExtra("binPath", binPath)
                        putExtra("homePath", homePath)
                        putExtra("tmpPath", tmpPath)
                        putExtra("ubuntuPath", ubuntuPath)
                        if (!uvIndexUrl.isNullOrBlank()) putExtra("uvIndexUrl", uvIndexUrl)
                        if (cols != null && cols > 0) putExtra("cols", cols)
                        if (rows != null && rows > 0) putExtra("rows", rows)
                        if (ipcReceiver != null) putExtra("resultReceiver", ipcReceiver)
                    }

                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !action.equals("stop", ignoreCase = true) && !action.equals("safe_terminate", ignoreCase = true)) {
                            mContext.startForegroundService(intent)
                        } else {
                            mContext.startService(intent)
                        }
                    } catch (e: Exception) {
                        if (needsAck) {
                            if (completed.compareAndSet(false, true)) {
                                result.success(false)
                            }
                        } else {
                            result.error("SERVICE_ERROR", e.message, null)
                        }
                        return@setMethodCallHandler
                    }

                    if (needsAck) {
                        mainHandler.postDelayed({
                            if (completed.compareAndSet(false, true)) {
                                result.success(true)
                            }
                        }, 5000L)
                    } else {
                        result.success(true)
                    }
                }
                "extract_asset" -> {
                    val assetPath = call.argument<String>("assetPath")
                    val targetPath = call.argument<String>("targetPath")
                    if (assetPath.isNullOrEmpty() || targetPath.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "assetPath and targetPath are required", null)
                    } else {
                        ioExecutor.execute {
                            try {
                                val lookupKey = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetPath)
                                val targetFile = File(targetPath)
                                targetFile.parentFile?.mkdirs()
                                val tempFile = File(targetFile.parentFile, "${targetFile.name}.part")
                                var totalBytes = 0L
                                mContext.assets.open(lookupKey).use { input ->
                                    FileOutputStream(tempFile).use { output ->
                                        val buffer = ByteArray(65536)
                                        var read: Int
                                        while (input.read(buffer).also { read = it } != -1) {
                                            output.write(buffer, 0, read)
                                            totalBytes += read
                                        }
                                        output.flush()
                                    }
                                }
                                if (targetFile.exists()) targetFile.delete()
                                if (!tempFile.renameTo(targetFile)) {
                                    throw java.io.IOException("Failed to rename temp asset file to $targetPath")
                                }
                                Handler(Looper.getMainLooper()).post {
                                    result.success(totalBytes)
                                }
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post {
                                    result.error("EXTRACT_FAILED", e.message, null)
                                }
                            }
                        }
                    }
                }
                "get_resource_usage" -> {
                    ioExecutor.execute {
                        val payload = sampleResourceUsage()
                        Handler(Looper.getMainLooper()).post {
                            result.success(payload)
                        }
                    }
                }
                "is_accessibility_enabled" -> {
                    result.success(isAccessibilityServiceEnabled())
                }
                "open_accessibility_settings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        mContext.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                "is_auto_start_enabled" -> {
                    result.success(BackendPrefs.isAutoStartEnabled(mContext))
                }
                "set_auto_start_enabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    BackendPrefs.setAutoStartEnabled(mContext, enabled)
                    val intent = Intent(mContext, ProotService::class.java).apply {
                        this.action = "SET_AUTO_START"
                        putExtra("enabled", enabled)
                    }
                    try {
                        mContext.startService(intent)
                    } catch (_: Exception) {}
                    result.success(true)
                }
                "set_wifi_lock_enabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    BackendPrefs.setWifiLockEnabled(mContext, enabled)
                    val intent = Intent(mContext, ProotService::class.java).apply {
                        this.action = "SET_WIFI_LOCK"
                        putExtra("enabled", enabled)
                    }
                    try {
                        mContext.startService(intent)
                    } catch (_: Exception) {}
                    result.success(true)
                }
                "exit_app" -> {
                    BackendPrefs.setUserStopped(mContext, true)
                    val completed = AtomicBoolean(false)
                    val mainHandler = Handler(Looper.getMainLooper())
                    fun finishAndKill() {
                        if (!completed.compareAndSet(false, true)) return
                        result.success(true)
                        finishAffinity()
                        mainHandler.postDelayed({
                            android.os.Process.killProcess(android.os.Process.myPid())
                        }, 100L)
                    }

                    val ipcReceiver = createIpcResultReceiver(mainHandler) {
                        finishAndKill()
                    }
                    val stopIntent = Intent(mContext, ProotService::class.java).apply {
                        action = "STOP"
                        putExtra("resultReceiver", ipcReceiver)
                    }
                    try {
                        mContext.startService(stopIntent)
                    } catch (_: Exception) {
                        finishAndKill()
                    }
                    mainHandler.postDelayed({ finishAndKill() }, 1200L)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        flutterFragment?.onPostResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        flutterFragment?.onNewIntent(intent)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (flutterFragment != null) {
            flutterFragment?.onBackPressed()
        } else {
            super.onBackPressed()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        flutterFragment?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        flutterFragment?.onUserLeaveHint()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        flutterFragment?.onTrimMemory(level)
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        try {
            val am = mContext.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            if (am != null) {
                val services = am.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                if (services != null) {
                    for (s in services) {
                        val id = s.id
                        if (id != null && id.startsWith(packageName)) {
                            return true
                        }
                    }
                }
            }
        } catch (_: Exception) {}

        var accessibilityEnabled = 0
        val expectedServiceName = "$packageName/${KeepAliveAccessibilityService::class.java.canonicalName}"
        try {
            accessibilityEnabled = Settings.Secure.getInt(
                mContext.contentResolver,
                Settings.Secure.ACCESSIBILITY_ENABLED
            )
        } catch (_: Settings.SettingNotFoundException) {}

        if (accessibilityEnabled == 1) {
            val settingValue = Settings.Secure.getString(
                mContext.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            )
            if (settingValue != null) {
                val splitter = TextUtils.SimpleStringSplitter(':')
                splitter.setString(settingValue)
                while (splitter.hasNext()) {
                    val accessService = splitter.next()
                    if (accessService.equals(expectedServiceName, ignoreCase = true) ||
                        accessService.contains("$packageName/.KeepAliveAccessibilityService") ||
                        accessService.contains("$packageName/com.maibot.maibot_android.KeepAliveAccessibilityService")
                    ) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private fun createIpcResultReceiver(
        handler: Handler,
        onComplete: () -> Unit
    ): ResultReceiver {
        val localReceiver = object : ResultReceiver(handler) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                onComplete()
            }
        }
        val parcel = Parcel.obtain()
        return try {
            localReceiver.writeToParcel(parcel, 0)
            parcel.setDataPosition(0)
            ResultReceiver.CREATOR.createFromParcel(parcel)
        } finally {
            parcel.recycle()
        }
    }

    private fun readProcessMemoryMb(dir: File): Double {
        val smapsRollup = File(dir, "smaps_rollup")
        if (smapsRollup.canRead()) {
            try {
                smapsRollup.bufferedReader().use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.startsWith("Pss:")) {
                            val kb = extractLeadingNumber(line, 4)
                            if (kb >= 0.0) return kb / 1024.0
                            break
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        val statusFile = File(dir, "status")
        if (statusFile.canRead()) {
            try {
                statusFile.bufferedReader().use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.startsWith("VmRSS:")) {
                            val kb = extractLeadingNumber(line, 6)
                            if (kb >= 0.0) return kb / 1024.0
                            break
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return 0.0
    }

    private fun extractLeadingNumber(line: String, startOffset: Int): Double {
        var i = startOffset
        val len = line.length
        while (i < len && line[i].isWhitespace()) i++
        val start = i
        while (i < len && line[i].isDigit()) i++
        if (start == i) return -1.0
        return line.substring(start, i).toDoubleOrNull() ?: -1.0
    }

    private fun sampleResourceUsage(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        am?.getMemoryInfo(memInfo)

        val systemTotalMb = memInfo.totalMem / (1024.0 * 1024.0)
        val systemAvailMb = memInfo.availMem / (1024.0 * 1024.0)

        var appProcessMb = 0.0
        val appPidSet = HashSet<Int>()
        try {
            val running = am?.runningAppProcesses
            if (running != null) {
                val myUid = android.os.Process.myUid()
                val pids = running.filter { it.uid == myUid }.map { it.pid }.toIntArray()
                for (p in pids) appPidSet.add(p)
                if (pids.isNotEmpty()) {
                    val memInfos = am.getProcessMemoryInfo(pids)
                    for (info in memInfos) {
                        appProcessMb += info.totalPss / 1024.0
                    }
                }
            }
        } catch (_: Exception) {}

        var totalProcJiffies = 0L
        var containerMemoryMb = 0.0
        var containerProcessCount = 0

        try {
            val procDirs = File("/proc").listFiles { f ->
                f.isDirectory && f.name.all { it.isDigit() }
            }
            if (procDirs != null) {
                for (dir in procDirs) {
                    val pid = dir.name.toIntOrNull() ?: continue
                    val statFile = File(dir, "stat")
                    if (!statFile.canRead()) continue
                    try {
                        val statText = statFile.readText()
                        val rParen = statText.lastIndexOf(')')
                        if (rParen <= 0 || rParen + 2 >= statText.length) continue
                        val commStart = statText.indexOf('(')
                        val comm = if (commStart in 0 until rParen) statText.substring(commStart + 1, rParen) else ""
                        val lowerComm = comm.lowercase()
                        val isAppPid = appPidSet.contains(pid)
                        val isContainerProc = !isAppPid && (
                            lowerComm.contains("proot") ||
                                lowerComm.contains("python") ||
                                lowerComm == "uv" ||
                                lowerComm == "uvx" ||
                                lowerComm == "bash" ||
                                lowerComm == "sh" ||
                                lowerComm == "script" ||
                                lowerComm == "node"
                            )
                        if (!isAppPid && !isContainerProc) continue

                        val rest = statText.substring(rParen + 2).trim().split(Regex("\\s+"))
                        if (rest.size > 12) {
                            val utime = rest[11].toLongOrNull() ?: 0L
                            val stime = rest[12].toLongOrNull() ?: 0L
                            totalProcJiffies += (utime + stime)
                        }

                        if (isContainerProc) {
                            containerProcessCount++
                            containerMemoryMb += readProcessMemoryMb(dir)
                        }
                    } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}

        val nowMs = SystemClock.elapsedRealtime()
        var cpuPercent = 0.0
        if (lastProcJiffies >= 0L && lastSampleElapsedMs > 0L) {
            val deltaMs = nowMs - lastSampleElapsedMs
            val deltaJiffies = (totalProcJiffies - lastProcJiffies).coerceAtLeast(0L)
            if (deltaMs > 100L) {
                val clkTck = try {
                    Os.sysconf(OsConstants._SC_CLK_TCK).takeIf { it > 0 } ?: 100L
                } catch (_: Exception) {
                    100L
                }
                val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
                cpuPercent = ((deltaJiffies.toDouble() / clkTck) / (deltaMs / 1000.0 * cores) * 100.0)
                    .coerceIn(0.0, 100.0)
            }
        }
        lastProcJiffies = totalProcJiffies
        lastSampleElapsedMs = nowMs

        return mapOf(
            "cpuPercent" to cpuPercent,
            "appMemoryMb" to (appProcessMb + containerMemoryMb),
            "containerMemoryMb" to containerMemoryMb,
            "processCount" to containerProcessCount,
            "systemAvailMb" to systemAvailMb,
            "systemTotalMb" to systemTotalMb
        )
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(finishUiReceiver)
        } catch (_: Exception) {}
        ioExecutor.shutdownNow()
        if (instance === this) {
            instance = null
        }
        val flutterEngine = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (flutterEngine != null) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "maibot_channel").setMethodCallHandler(null)
        }
        super.onDestroy()
    }
}
