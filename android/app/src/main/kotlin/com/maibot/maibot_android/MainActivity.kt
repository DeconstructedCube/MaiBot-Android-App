package com.maibot.maibot_android

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.view.accessibility.AccessibilityManager
import android.webkit.ValueCallback
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

@Suppress("DEPRECATION")
class MainActivity : FragmentActivity() {

    companion object {
        @JvmStatic
        var instance: MainActivity? = null
            private set

        private const val TAG_FLUTTER_FRAGMENT = "flutter_fragment"
        private const val ENGINE_ID = "my_engine_id"
        private const val FILE_CHOOSER_REQUEST_CODE = 1
    }

    private var flutterFragment: FlutterFragment? = null
    private lateinit var mContext: Context
    private lateinit var fragmentManager: FragmentManager
    private var filePathCallback: ValueCallback<Array<Uri>>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        instance = this
        mContext = this

        // 用户主动启动应用，重置显式停止标志
        val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
        sp.edit().putBoolean("user_stopped", false).apply()
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

                    val sp = mContext.getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
                    if (action.equals("stop", ignoreCase = true) && target.equals("all", ignoreCase = true)) {
                        sp.edit().putBoolean("user_stopped", true).apply()
                    } else if (action.equals("start", ignoreCase = true) || action.equals("restart", ignoreCase = true)) {
                        sp.edit().putBoolean("user_stopped", false).apply()
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
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        mContext.startForegroundService(intent)
                    } else {
                        mContext.startService(intent)
                    }
                    result.success(true)
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
                    val sp = mContext.getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
                    result.success(sp.getBoolean("auto_start_enabled", true))
                }
                "set_auto_start_enabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    val sp = mContext.getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
                    sp.edit().putBoolean("auto_start_enabled", enabled).apply()
                    result.success(true)
                }
                "set_wifi_lock_enabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val sp = mContext.getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
                    sp.edit().putBoolean("wifi_lock_enabled", enabled).apply()
                    val intent = Intent(mContext, ProotService::class.java).apply {
                        this.action = "SET_WIFI_LOCK"
                        putExtra("enabled", enabled)
                    }
                    try {
                        mContext.startService(intent)
                    } catch (_: Exception) {}
                    result.success(true)
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == FILE_CHOOSER_REQUEST_CODE) {
            val callback = filePathCallback ?: return
            var results: Array<Uri>? = null

            if (resultCode == Activity.RESULT_OK && data != null) {
                val dataString = data.dataString
                val clipData = data.clipData
                if (dataString != null) {
                    results = arrayOf(Uri.parse(dataString))
                } else if (clipData != null) {
                    val count = clipData.itemCount
                    results = Array(count) { i -> clipData.getItemAt(i).uri }
                }
            }

            callback.onReceiveValue(results)
            filePathCallback = null
        }

        flutterFragment?.onActivityResult(requestCode, resultCode, data)
    }

    fun openFileChooser(callback: ValueCallback<Array<Uri>>) {
        filePathCallback = callback

        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }

        val chooserIntent = Intent.createChooser(intent, "选择文件")
        startActivityForResult(chooserIntent, FILE_CHOOSER_REQUEST_CODE)
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

    fun triggerExitFromFlutter() {
        runOnUiThread {
            val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
            sp.edit().putBoolean("user_stopped", true).apply()
            val stopIntent = Intent(this, ProotService::class.java).apply {
                action = "STOP"
            }
            startService(stopIntent)
            finishAffinity()
        }
    }

    override fun onDestroy() {
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
