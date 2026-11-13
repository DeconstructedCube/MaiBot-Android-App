package com.maibot.maibot_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 接收来自常驻通知栏操作按钮的退出指令
 */
class ExitReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "ExitReceiver"
        const val ACTION_EXIT = "com.maibot.maibot_android.ACTION_EXIT"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return
        if (ACTION_EXIT == intent.action) {
            Log.i(TAG, "收到通知栏退出指令广播，执行彻底退出")

            BackendPrefs.setUserStopped(context, true)

            // 通知主进程关闭 UI Activity（跨进程安全）
            val finishUiIntent = Intent(MainActivity.ACTION_FINISH_UI).apply {
                setPackage(context.packageName)
            }
            context.sendBroadcast(finishUiIntent)

            // 停止同属 :backend 进程的 ProotService 后台常驻服务并移除通知
            val stopIntent = Intent(context, ProotService::class.java).apply {
                action = "STOP"
            }
            context.startService(stopIntent)
        }
    }
}
