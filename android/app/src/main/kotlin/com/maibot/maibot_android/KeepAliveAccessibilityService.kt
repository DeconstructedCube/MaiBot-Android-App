package com.maibot.maibot_android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * 无障碍保活服务
 * 用于提升进程在系统中的存活优先级，防止用户划掉后台任务卡片时导致主进程与 Linux 容器被直接终止
 */
class KeepAliveAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "KeepAliveAccessibility"

        @JvmStatic
        var isRunning: Boolean = false
            private set

        @JvmStatic
        fun checkAndAutoStartBackend(context: Context) {
            try {
                if (BackendPrefs.isUserStopped(context)) {
                    Log.i(TAG, "用户之前已显式退出应用，禁止无障碍服务自动拉起")
                    return
                }

                if (!BackendPrefs.isAutoStartEnabled(context)) {
                    Log.i(TAG, "自启动已被用户关闭，跳过后台原生服务拉起")
                    return
                }
                val serviceIntent = Intent(context, ProotService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
                Log.i(TAG, "已成功触发 ProotService 后台自启动")
            } catch (e: Exception) {
                Log.e(TAG, "自启动 ProotService 失败: ", e)
            }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 无需拦截处理无障碍事件，仅作为系统级高优先级保活载体
    }

    override fun onInterrupt() {
        Log.i(TAG, "KeepAliveAccessibilityService onInterrupt")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        isRunning = true
        Log.i(TAG, "KeepAliveAccessibilityService onServiceConnected: 无障碍保活服务已启动并在 :backend 进程生效")

        val info = serviceInfo ?: AccessibilityServiceInfo()
        info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_ALL_MASK
        info.flags = (
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
            AccessibilityServiceInfo.FLAG_REQUEST_ENHANCED_WEB_ACCESSIBILITY or
            AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        )
        info.notificationTimeout = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE
        }
        serviceInfo = info

        // 无障碍服务连接就绪时，执行自启动检查与后台原生服务拉起
        checkAndAutoStartBackend(this)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved: 用户划掉多任务卡片，无障碍服务继续锚定 :backend 进程")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        Log.i(TAG, "KeepAliveAccessibilityService onDestroy: 无障碍保活服务已销毁")
        super.onDestroy()
    }
}
