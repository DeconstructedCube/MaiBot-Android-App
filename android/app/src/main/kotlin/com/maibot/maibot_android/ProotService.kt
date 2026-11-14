package com.maibot.maibot_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.os.ResultReceiver
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * 跨进程一致的轻量标志位存储（基于 filesDir 标志文件，规避 SharedPreferences 跨进程内存缓存脑裂）
 */
object BackendPrefs {
    private fun flagDir(context: Context): File = File(context.filesDir, ".backend_prefs").apply {
        if (!exists()) mkdirs()
    }

    fun isUserStopped(context: Context): Boolean = File(flagDir(context), "user_stopped.flag").exists()

    fun setUserStopped(context: Context, stopped: Boolean) {
        val file = File(flagDir(context), "user_stopped.flag")
        if (stopped) {
            if (!file.exists()) try { file.createNewFile() } catch (_: Exception) {}
        } else {
            if (file.exists()) try { file.delete() } catch (_: Exception) {}
        }
    }

    fun isAutoStartEnabled(context: Context): Boolean = !File(flagDir(context), "auto_start_disabled.flag").exists()

    fun setAutoStartEnabled(context: Context, enabled: Boolean) {
        val file = File(flagDir(context), "auto_start_disabled.flag")
        if (!enabled) {
            if (!file.exists()) try { file.createNewFile() } catch (_: Exception) {}
        } else {
            if (file.exists()) try { file.delete() } catch (_: Exception) {}
        }
    }

    fun isWifiLockEnabled(context: Context): Boolean = !File(flagDir(context), "wifi_lock_disabled.flag").exists()

    fun setWifiLockEnabled(context: Context, enabled: Boolean) {
        val file = File(flagDir(context), "wifi_lock_disabled.flag")
        if (!enabled) {
            if (!file.exists()) try { file.createNewFile() } catch (_: Exception) {}
        } else {
            if (file.exists()) try { file.delete() } catch (_: Exception) {}
        }
    }
}

enum class ServiceState(val value: String) {
    STOPPED("STOPPED"),
    STARTING("STARTING"),
    RUNNING("RUNNING"),
    STOPPING("STOPPING"),
    RESTARTING("RESTARTING"),
    ERROR("ERROR")
}

/**
 * 固定容量环形字节缓冲区（零碎块分配，常数时间写入与快照导出）
 */
class ByteRingBuffer(private val capacity: Int = 262144) {
    private val buffer = ByteArray(capacity)
    private var head = 0
    private var size = 0

    @Synchronized
    fun write(data: ByteArray, offset: Int = 0, length: Int = data.size) {
        if (length <= 0) return
        if (length >= capacity) {
            val startOff = offset + (length - capacity)
            System.arraycopy(data, startOff, buffer, 0, capacity)
            head = 0
            size = capacity
            return
        }
        val writePos = (head + size) % capacity
        val firstPart = minOf(length, capacity - writePos)
        System.arraycopy(data, offset, buffer, writePos, firstPart)
        val secondPart = length - firstPart
        if (secondPart > 0) {
            System.arraycopy(data, offset + firstPart, buffer, 0, secondPart)
        }
        if (size + length > capacity) {
            val overflow = (size + length) - capacity
            head = (head + overflow) % capacity
            size = capacity
        } else {
            size += length
        }
    }

    @Synchronized
    fun snapshot(): ByteArray {
        if (size == 0) return ByteArray(0)
        val out = ByteArray(size)
        val firstPart = minOf(size, capacity - head)
        System.arraycopy(buffer, head, out, 0, firstPart)
        val secondPart = size - firstPart
        if (secondPart > 0) {
            System.arraycopy(buffer, 0, out, firstPart, secondPart)
        }
        return out
    }

    @Synchronized
    fun clear() {
        head = 0
        size = 0
    }
}

class ProotService : Service() {

    companion object {
        private const val TAG = "ProotService"
        private const val CHANNEL_ID = "maibot_native_backend"
        private const val NOTIFICATION_ID = 1002

        // 5-Byte Length-Prefixed Binary Frame Types
        const val FRAME_PTY_DATA: Byte = 0x01
        const val FRAME_HISTORY_DATA: Byte = 0x02
        const val FRAME_CONTROL_JSON: Byte = 0x03

        fun packFrame(type: Byte, payload: ByteArray, offset: Int = 0, length: Int = payload.size): ByteArray {
            val frame = ByteArray(5 + length)
            frame[0] = type
            frame[1] = ((length ushr 24) and 0xFF).toByte()
            frame[2] = ((length ushr 16) and 0xFF).toByte()
            frame[3] = ((length ushr 8) and 0xFF).toByte()
            frame[4] = (length and 0xFF).toByte()
            if (length > 0) {
                System.arraycopy(payload, offset, frame, 5, length)
            }
            return frame
        }
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val commandChannel = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var maibotProcess: ProotProcess? = null
    private var isForegroundActive = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MaiBot::BackendLock").apply {
            acquire()
        }
        updateWifiLock(BackendPrefs.isWifiLockEnabled(this))
        serviceScope.launch {
            for (cmd in commandChannel) {
                try {
                    cmd()
                } catch (e: Exception) {
                    Log.e(TAG, "Command execution error", e)
                }
            }
        }
    }

    private fun ensureForegroundNotification() {
        if (isForegroundActive) return
        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val exitIntent = Intent(this, ExitReceiver::class.java).apply {
            action = ExitReceiver.ACTION_EXIT
        }
        val exitPendingIntent = PendingIntent.getBroadcast(
            this,
            0,
            exitIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MaiBot 后台服务")
            .setContentText("容器与服务正在后台运行")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "退出应用", exitPendingIntent)
            .setOngoing(true)
            .build()

        try {
            startForeground(NOTIFICATION_ID, notification)
            isForegroundActive = true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground error", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun updateWifiLock(enabled: Boolean) {
        try {
            if (enabled) {
                if (wifiLock == null) {
                    val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                    } else {
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    wifiLock = wm?.createWifiLock(mode, "MaiBot::BackendWifiLock")?.apply {
                        setReferenceCounted(false)
                    }
                }
                if (wifiLock?.isHeld == false) {
                    wifiLock?.acquire()
                }
            } else {
                if (wifiLock?.isHeld == true) {
                    wifiLock?.release()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "updateWifiLock error", e)
        }
    }

    private fun readResultReceiver(intent: Intent?): ResultReceiver? {
        if (intent == null) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra("resultReceiver", ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra("resultReceiver")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
        val action = intent?.action
        val userStopped = BackendPrefs.isUserStopped(this)
        val resultReceiver = readResultReceiver(intent)

        if ("SET_WIFI_LOCK" == action) {
            val enabled = intent.getBooleanExtra("enabled", true)
            BackendPrefs.setWifiLockEnabled(this, enabled)
            updateWifiLock(enabled)
            resultReceiver?.send(0, null)
            return START_NOT_STICKY
        }
        if ("SET_AUTO_START" == action) {
            val enabled = intent.getBooleanExtra("enabled", true)
            BackendPrefs.setAutoStartEnabled(this, enabled)
            resultReceiver?.send(0, null)
            return START_NOT_STICKY
        }

        // 处理 STOP 指令：立即安全停机，绝不二次启动服务或重新挂载前台通知
        val isStopAction = "STOP".equals(action, ignoreCase = true) ||
                ("CONTROL".equals(action, ignoreCase = true) && "STOP".equals(intent?.getStringExtra("action"), ignoreCase = true))
        if (isStopAction) {
            Log.i(TAG, "收到明确停机指令 (action=$action)，立即终止后台所有进程并撤回前台通知")
            BackendPrefs.setUserStopped(this, true)

            serviceScope.launch {
                try {
                    safelyTerminateAllProcesses()
                } finally {
                    resultReceiver?.send(0, Bundle())
                    withContext(Dispatchers.Main) {
                        stopForegroundAndSelf()
                    }
                }
            }
            return START_NOT_STICKY
        }

        if (userStopped && action != "CONTROL" && action != "START") {
            Log.i(TAG, "用户之前已显式退出应用，禁止后台自动唤醒")
            resultReceiver?.send(0, null)
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        if (intent != null) {
            var binPath = intent.getStringExtra("binPath")
            var homePath = intent.getStringExtra("homePath")
            var tmpPath = intent.getStringExtra("tmpPath")
            var ubuntuPath = intent.getStringExtra("ubuntuPath")
            val uvIndexUrl = intent.getStringExtra("uvIndexUrl")
            val cols = intent.getIntExtra("cols", 0).takeIf { it in 40..200 }
            val rows = intent.getIntExtra("rows", 0).takeIf { it in 16..100 }

            if (binPath != null && homePath != null) {
                sp.edit().apply {
                    putString("binPath", binPath)
                    putString("homePath", homePath)
                    putString("tmpPath", tmpPath)
                    putString("ubuntuPath", ubuntuPath)
                    if (!uvIndexUrl.isNullOrBlank()) putString("uvIndexUrl", uvIndexUrl)
                    if (cols != null) putInt("cols", cols)
                    if (rows != null) putInt("rows", rows)
                }.apply()
            } else {
                if (!BackendPrefs.isAutoStartEnabled(this) && action == null) {
                    Log.i(TAG, "自启动已被用户关闭，ProotService 保持待命状态")
                    resultReceiver?.send(0, null)
                    return START_NOT_STICKY
                }
                binPath = sp.getString("binPath", null) ?: "${filesDir.absolutePath}/usr/bin"
                homePath = sp.getString("homePath", null) ?: "${filesDir.absolutePath}/home"
                tmpPath = sp.getString("tmpPath", null) ?: "${filesDir.absolutePath}/usr/tmp"
                ubuntuPath = sp.getString("ubuntuPath", null)
                    ?: "${filesDir.absolutePath}/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
            }

            val curBin = binPath ?: "${filesDir.absolutePath}/usr/bin"
            val curHome = homePath ?: "${filesDir.absolutePath}/home"
            val curTmp = tmpPath ?: "${filesDir.absolutePath}/usr/tmp"
            val curUbuntu = ubuntuPath ?: "${filesDir.absolutePath}/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
            val curUvIndex = uvIndexUrl?.takeIf { it.isNotBlank() }
                ?: sp.getString("uvIndexUrl", null)
                ?: "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
            val curCols = cols ?: sp.getInt("cols", 60).coerceIn(40, 200)
            val curRows = rows ?: sp.getInt("rows", 28).coerceIn(16, 100)
            val ctrlAction = intent.getStringExtra("action")?.uppercase() ?: "START"
            val ctrlTarget = intent.getStringExtra("target")?.uppercase() ?: "ALL"

            ensureForegroundNotification()

            commandChannel.trySend {
                try {
                    handleCommandAsync(action, ctrlAction, ctrlTarget, curBin, curHome, curTmp, curUbuntu, curUvIndex, curCols, curRows)
                } finally {
                    resultReceiver?.send(0, Bundle())
                }
            }
        } else {
            resultReceiver?.send(0, null)
        }
        return START_NOT_STICKY
    }

    private suspend fun handleCommandAsync(
        action: String?,
        ctrlAction: String,
        ctrlTarget: String,
        curBin: String,
        curHome: String,
        curTmp: String,
        curUbuntu: String,
        curUvIndex: String,
        curCols: Int,
        curRows: Int
    ) {
        if ("CONTROL" == action) {
            Log.i(TAG, "收到控制指令: action=$ctrlAction, target=$ctrlTarget")
            when (ctrlAction) {
                "START" -> {
                    BackendPrefs.setUserStopped(this, false)
                    if (ctrlTarget == "ALL" || ctrlTarget == "MAIBOT") {
                        startMaiBot(curBin, curHome, curTmp, curUbuntu, curUvIndex, curCols, curRows)
                    }
                }
                "STOP" -> {
                    if (ctrlTarget == "MAIBOT") {
                        maibotProcess?.stop()
                        maibotProcess = null
                        terminateOrphanDaemonProcesses()
                    } else if (ctrlTarget == "ALL") {
                        BackendPrefs.setUserStopped(this, true)
                        safelyTerminateAllProcesses()
                        withContext(Dispatchers.Main) {
                            stopForegroundAndSelf()
                        }
                    }
                }
                "RESTART" -> {
                    BackendPrefs.setUserStopped(this, false)
                    if (ctrlTarget == "MAIBOT" || ctrlTarget == "ALL") {
                        startMaiBot(curBin, curHome, curTmp, curUbuntu, curUvIndex, curCols, curRows, forceRestart = true)
                    }
                }
                "SAFE_TERMINATE" -> {
                    safelyTerminateAllProcesses()
                }
            }
            return
        }

        val rootfsCheck = File(curUbuntu, "bin/bash")
        if (!rootfsCheck.exists()) {
            Log.w(TAG, "Ubuntu RootFS 未就绪 (${rootfsCheck.absolutePath} 不存在)，暂缓启动容器进程")
            return
        }

        startMaiBot(curBin, curHome, curTmp, curUbuntu, curUvIndex, curCols, curRows)
    }
    private fun stopForegroundAndSelf() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        isForegroundActive = false
        stopSelf()
    }

    private suspend fun startMaiBot(
        binPath: String,
        homePath: String,
        tmpPath: String,
        ubuntuPath: String,
        uvIndexUrl: String,
        cols: Int,
        rows: Int,
        forceRestart: Boolean = false
    ) {
        if (!forceRestart && maibotProcess?.isAlive() == true) {
            Log.d(TAG, "MaiBot 进程已在运行，跳过启动")
            return
        }
        if (maibotProcess != null) {
            maibotProcess?.stop()
            maibotProcess = null
        }
        terminateOrphanDaemonProcesses()

        Log.i(TAG, "启动 MaiBot 服务进程 (cols=$cols, rows=$rows)...")
        val maibotCmd = """
            export PATH=/root/MaiBot/.venv/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export TERM=xterm-256color
            export COLORTERM=truecolor
            export FORCE_COLOR=1
            export CLICOLOR_FORCE=1
            export CLICOLOR=1
            export PYTHONUNBUFFERED=1
            export PYTHONIOENCODING=utf-8
            export PYTHON_COLORS=1
            export RICH_FORCE_COLOR=1
            export LOGURU_COLORIZE=true
            export UV_COLOR=always
            export UV_PROGRESS_MODE=visual
            export UV_NO_PROGRESS=0
            export UV_INDEX_URL='$uvIndexUrl'
            export PIP_NO_COLOR=0
            export COLUMNS=$cols
            export LINES=$rows
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8
            export UV_LINK_MODE=copy
            export TMPDIR=/tmp
            export TEMP=/tmp
            export TMP=/tmp
            mkdir -p /tmp /var/tmp
            cd /root/MaiBot
            export MAIBOT_LEGACY_0X_UPGRADE_CONFIRMED=1
            if [ -f EULA.md ]; then export EULA_AGREE=$(md5sum EULA.md | awk '{print $1}'); md5sum EULA.md | awk '{printf "%s", $1}' > eula.confirmed; fi
            if [ -f PRIVACY.md ]; then export PRIVACY_AGREE=$(md5sum PRIVACY.md | awk '{print $1}'); md5sum PRIVACY.md | awk '{printf "%s", $1}' > privacy.confirmed; fi
            if [ -f /root/MaiBot/.venv_sync_ready ] && [ -x /root/MaiBot/.venv/bin/python ]; then
                RUN_CMD="/root/MaiBot/.venv/bin/python -u bot.py"
            else
                RUN_CMD="/root/.local/bin/uv run --color always bot.py"
            fi
            if command -v script >/dev/null 2>&1; then
                exec script -q -e -c "stty cols $cols rows $rows 2>/dev/null; ${'$'}RUN_CMD" /dev/null
            else
                exec ${'$'}RUN_CMD
            fi
        """.trimIndent() + "\n"

        maibotProcess = ProotProcess("MaiBot", 20001, binPath, homePath, tmpPath, ubuntuPath, maibotCmd, uvIndexUrl, cols, rows).apply {
            start()
        }
    }

    private data class ProcEntry(
        val pid: Int,
        val ppid: Int,
        val pgrp: Int,
        val session: Int,
        val isDaemonMarked: Boolean
    )

    private fun hasDaemonMarker(environFile: File): Boolean {
        return try {
            if (!environFile.canRead()) return false
            val raw = environFile.readBytes()
            val marker = "MAIBOT_PROC_ROLE=daemon".toByteArray(Charsets.US_ASCII)
            if (raw.size < marker.size) return false
            outer@ for (i in 0..(raw.size - marker.size)) {
                if (i > 0 && raw[i - 1] != 0.toByte()) continue
                val end = i + marker.size
                if (end < raw.size && raw[end] != 0.toByte()) continue
                for (j in marker.indices) {
                    if (raw[i + j] != marker[j]) continue@outer
                }
                return true
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun snapshotProcEntries(): List<ProcEntry> {
        val myPid = android.os.Process.myPid()
        val procDirs = File("/proc").listFiles { f ->
            f.isDirectory && f.name.all { it.isDigit() }
        } ?: return emptyList()

        val entries = ArrayList<ProcEntry>(procDirs.size)
        for (dir in procDirs) {
            val pid = dir.name.toIntOrNull() ?: continue
            if (pid <= 1 || pid == myPid) continue
            val statFile = File(dir, "stat")
            if (!statFile.canRead()) continue
            try {
                val statText = statFile.readText()
                val rParen = statText.lastIndexOf(')')
                if (rParen <= 0 || rParen + 2 >= statText.length) continue
                val fields = statText.substring(rParen + 2).trim().split(Regex("\\s+"))
                if (fields.size < 4) continue
                val ppid = fields[1].toIntOrNull() ?: -1
                val pgrp = fields[2].toIntOrNull() ?: -1
                val session = fields[3].toIntOrNull() ?: -1
                val marked = hasDaemonMarker(File(dir, "environ"))
                entries.add(ProcEntry(pid, ppid, pgrp, session, marked))
            } catch (_: Exception) {}
        }
        return entries
    }

    private fun collectManagedPids(rootPid: Long): Set<Int> {
        val entries = snapshotProcEntries()
        if (entries.isEmpty()) return emptySet()

        val childrenMap = HashMap<Int, MutableList<Int>>()
        var rootPgrp = -1
        var rootSession = -1
        val targetPids = LinkedHashSet<Int>()

        for (entry in entries) {
            childrenMap.getOrPut(entry.ppid) { ArrayList() }.add(entry.pid)
            if (rootPid > 0 && entry.pid.toLong() == rootPid) {
                rootPgrp = entry.pgrp
                rootSession = entry.session
                targetPids.add(entry.pid)
            }
            if (entry.isDaemonMarked) {
                targetPids.add(entry.pid)
            }
        }

        if (rootPgrp > 1 || rootSession > 1) {
            for (entry in entries) {
                if ((rootPgrp > 1 && entry.pgrp == rootPgrp) ||
                    (rootSession > 1 && entry.session == rootSession)
                ) {
                    targetPids.add(entry.pid)
                }
            }
        }

        val queue = ArrayDeque<Int>(targetPids)
        while (queue.isNotEmpty()) {
            val cur = queue.removeFirst()
            val kids = childrenMap[cur] ?: continue
            for (kid in kids) {
                if (targetPids.add(kid)) {
                    queue.addLast(kid)
                }
            }
        }
        return targetPids
    }

    private fun isProcessAliveCompat(p: Process): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return p.isAlive
        }
        return try {
            p.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        }
    }

    private fun sendSignal(pid: Int, signal: Int) {
        try {
            Os.kill(pid, signal)
        } catch (_: Exception) {}
    }

    private suspend fun terminateProcessTree(rootPid: Long, proc: Process?) {
        val initialPids = collectManagedPids(rootPid)
        if (initialPids.isEmpty() && (proc == null || !isProcessAliveCompat(proc))) {
            return
        }

        if (rootPid > 1) {
            sendSignal(-rootPid.toInt(), OsConstants.SIGINT)
        }
        for (pid in initialPids) {
            sendSignal(pid, OsConstants.SIGINT)
        }

        for (i in 0 until 20) {
            delay(60)
            val aliveProc = proc != null && isProcessAliveCompat(proc)
            val remaining = collectManagedPids(rootPid)
            if (!aliveProc && remaining.isEmpty()) {
                return
            }
        }

        val survivors = collectManagedPids(rootPid)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            proc?.destroyForcibly()
        } else {
            proc?.destroy()
        }
        if (rootPid > 1) {
            sendSignal(-rootPid.toInt(), OsConstants.SIGKILL)
        }
        for (pid in survivors) {
            sendSignal(pid, OsConstants.SIGKILL)
        }

        for (i in 0 until 10) {
            delay(50)
            val aliveProc = proc != null && isProcessAliveCompat(proc)
            val remaining = collectManagedPids(rootPid)
            if (!aliveProc && remaining.isEmpty()) {
                break
            }
        }
    }

    private suspend fun terminateOrphanDaemonProcesses() {
        val orphans = collectManagedPids(-1L)
        if (orphans.isNotEmpty()) {
            Log.i(TAG, "清理残留 MaiBot 进程树: $orphans")
            terminateProcessTree(-1L, null)
        }
    }

    private suspend fun safelyTerminateAllProcesses() {
        maibotProcess?.stop()
        maibotProcess = null
        terminateOrphanDaemonProcesses()
    }

    override fun onDestroy() {
        commandChannel.close()
        val activeProcess = maibotProcess
        if (activeProcess != null || collectManagedPids(-1L).isNotEmpty()) {
            runBlocking(Dispatchers.IO) {
                withTimeoutOrNull(1500L) {
                    safelyTerminateAllProcesses()
                }
            }
        }
        serviceScope.cancel()

        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        super.onDestroy()
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved: 用户划掉多任务卡片，ProotService 保持后台持续运行")
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID, "Native Backend", NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(serviceChannel)
        }
    }


    /**
     * 单个客户端异步连接会话：内置有界非阻塞发送队列，杜绝慢客户端引起容器 stdout 背压死锁
     */
    private inner class ClientSession(
        val socket: Socket,
        private val onDisconnected: (ClientSession) -> Unit
    ) {
        private val writeQueue = Channel<ByteArray>(
            capacity = 256,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
        private var writerJob: Job? = null

        fun startWriter(initialFrames: List<ByteArray>) {
            for (frame in initialFrames) {
                writeQueue.trySend(frame)
            }
            writerJob = serviceScope.launch {
                try {
                    val out: OutputStream = socket.getOutputStream()
                    for (frame in writeQueue) {
                        out.write(frame)
                        if (writeQueue.isEmpty) {
                            out.flush()
                        }
                    }
                } catch (_: IOException) {
                } finally {
                    close()
                }
            }
        }

        fun enqueueFrame(frame: ByteArray) {
            writeQueue.trySend(frame)
        }

        fun close() {
            writeQueue.close()
            writerJob?.cancel()
            try {
                socket.close()
            } catch (_: IOException) {}
            onDisconnected(this)
        }
    }

    private inner class ProotProcess(
        private val name: String,
        private val port: Int,
        private val binPath: String,
        private val homePath: String,
        private val tmpPath: String,
        private val ubuntuPath: String,
        private val command: String,
        private val uvIndexUrl: String,
        private val cols: Int,
        private val rows: Int
    ) {
        private var process: Process? = null
        private var serverSocket: ServerSocket? = null
        private val clients = CopyOnWriteArrayList<ClientSession>()
        private val historyBuffer = ByteRingBuffer(262144)

        private var restartCount = 0
        private var restartJob: Job? = null
        private var startJob: Job? = null
        private var acceptJob: Job? = null
        private var stdoutJob: Job? = null

        @Volatile
        var isStopped = false

        @Volatile
        var currentState: ServiceState = ServiceState.STOPPED
            private set
        @Volatile
        private var currentPid: Long = -1L

        private fun extractPid(p: Process): Long {
            return try {
                val field = p.javaClass.getDeclaredField("pid")
                field.isAccessible = true
                field.getInt(p).toLong()
            } catch (_: Exception) {
                Regex("pid=(\\d+)").find(p.toString())?.groupValues?.get(1)?.toLongOrNull() ?: -1L
            }
        }

        private fun buildStateFrame(state: ServiceState, pid: Long = -1): ByteArray {
            val json = "{\"service\":\"${name.lowercase()}\",\"state\":\"${state.value}\",\"retry\":$restartCount,\"pid\":$pid}"
            val payload = json.toByteArray(Charsets.UTF_8)
            return packFrame(FRAME_CONTROL_JSON, payload)
        }

        private fun notifyState(state: ServiceState, pid: Long = -1) {
            currentState = state
            val frame = buildStateFrame(state, pid)
            for (client in clients) {
                client.enqueueFrame(frame)
            }
        }

        private suspend fun initServerSocket() {
            val existing = serverSocket
            if (existing != null && !existing.isClosed && existing.isBound) {
                return
            }
            try {
                serverSocket?.close()
            } catch (_: Exception) {}
            serverSocket = null

            try {
                serverSocket = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress("127.0.0.1", port))
                }
            } catch (e: IOException) {
                Log.w(TAG, "$name 端口 $port 初次绑定失败 (${e.message})，延迟重试...")
                delay(300)
                try {
                    serverSocket = ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress("127.0.0.1", port))
                    }
                } catch (ex: Exception) {
                    Log.e(TAG, "$name 端口 $port 绑定彻底失败", ex)
                    return
                }
            }

            val ss = serverSocket ?: return
            acceptJob?.cancel()
            acceptJob = serviceScope.launch {
                while (isActive && !isStopped && !ss.isClosed) {
                    try {
                        val socket = ss.accept()
                        val session = ClientSession(socket) { removed ->
                            clients.remove(removed)
                        }
                        val histBytes = historyBuffer.snapshot()
                        val initFrames = ArrayList<ByteArray>(2)
                        if (histBytes.isNotEmpty()) {
                            initFrames.add(packFrame(FRAME_HISTORY_DATA, histBytes))
                        }
                        initFrames.add(buildStateFrame(currentState, currentPid))

                        clients.add(session)
                        session.startWriter(initFrames)

                        // 启动客户端上行输入转发协程
                        launch {
                            try {
                                val input: InputStream = socket.getInputStream()
                                val inBuffer = ByteArray(1024)
                                while (isActive && !isStopped) {
                                    val inRead = input.read(inBuffer)
                                    if (inRead == -1) break
                                    val p = process
                                    if (p != null) {
                                        val pStdin = p.outputStream
                                        pStdin?.write(inBuffer, 0, inRead)
                                        pStdin?.flush()
                                    }
                                }
                            } catch (_: IOException) {
                            } finally {
                                session.close()
                            }
                        }
                    } catch (e: IOException) {
                        if (!isStopped) {
                            Log.d(TAG, "$name accept loop ended: ${e.message}")
                        }
                        break
                    }
                }
            }
        }

        @Synchronized
        fun start() {
            if (isStopped) {
                isStopped = false
            }
            if (process != null && isAlive()) {
                Log.d(TAG, "$name 进程依然存活，无需重复启动")
                notifyState(ServiceState.RUNNING, currentPid)
                return
            }
            restartJob?.cancel()
            restartJob = null
            startJob?.cancel()
            notifyState(ServiceState.STARTING)

            startJob = serviceScope.launch {
                try {
                    initServerSocket()
                    if (isStopped) return@launch
                    historyBuffer.clear()

                    val cmd = mutableListOf<String>()
                    val busyboxFile = File("$binPath/busybox")
                    if (busyboxFile.exists()) {
                        cmd.add(busyboxFile.absolutePath)
                        cmd.add("setsid")
                    }
                    cmd.addAll(
                        listOf(
                            "$binPath/proot",
                            "-0",
                            "-r", ubuntuPath,
                            "--link2symlink",
                            "-b", "/dev",
                            "-b", "/proc",
                            "-b", "/sys",
                            "-b", "$tmpPath:/tmp",
                            "-b", "$tmpPath:/dev/shm",
                            "-w", "/root"
                        )
                    )

                    // Fake sysdata bindings to prevent Python/uv crashes on restricted Android /proc
                    val fakeProcs = arrayOf(
                        ".loadavg", ".stat", ".uptime", ".version", ".vmstat",
                        ".meminfo", ".cpuinfo",
                        ".sysctl_entry_cap_last_cap", ".sysctl_inotify_max_user_watches"
                    )
                    val targetProcs = arrayOf(
                        "/proc/loadavg", "/proc/stat", "/proc/uptime", "/proc/version", "/proc/vmstat",
                        "/proc/meminfo", "/proc/cpuinfo",
                        "/proc/sys/kernel/cap_last_cap", "/proc/sys/fs/inotify/max_user_watches"
                    )
                    for (i in fakeProcs.indices) {
                        val fakeFile = File("$ubuntuPath/proc/${fakeProcs[i]}")
                        if (fakeFile.exists()) {
                            cmd.add("-b")
                            cmd.add("${fakeFile.absolutePath}:${targetProcs[i]}")
                        }
                    }
                    cmd.add("/bin/sh")

                    if (isStopped) return@launch

                    val pb = ProcessBuilder(cmd)
                    pb.environment().apply {
                        put("PATH", "$binPath:/system/bin:/system/xbin")
                        put("HOME", "/root")
                        put("PROOT_TMP_DIR", tmpPath)
                        put("PROOT_LOADER", "$binPath/loader")
                        put("LD_LIBRARY_PATH", binPath)
                        put("MAIBOT_PROC_ROLE", "daemon")
                        put("TERM", "xterm-256color")
                        put("COLORTERM", "truecolor")
                        put("FORCE_COLOR", "1")
                        put("CLICOLOR_FORCE", "1")
                        put("CLICOLOR", "1")
                        put("PYTHONUNBUFFERED", "1")
                        put("PYTHONIOENCODING", "utf-8")
                        put("PYTHON_COLORS", "1")
                        put("RICH_FORCE_COLOR", "1")
                        put("LOGURU_COLORIZE", "true")
                        put("UV_COLOR", "always")
                        put("UV_PROGRESS_MODE", "visual")
                        put("UV_NO_PROGRESS", "0")
                        put("UV_INDEX_URL", uvIndexUrl)
                        put("PIP_NO_COLOR", "0")
                        put("COLUMNS", cols.toString())
                        put("LINES", rows.toString())
                        put("LANG", "C.UTF-8")
                        put("LC_ALL", "C.UTF-8")
                        put("MAIBOT_LEGACY_0X_UPGRADE_CONFIRMED", "1")
                        put("TMPDIR", "/tmp")
                        put("TEMP", "/tmp")
                        put("TMP", "/tmp")
                    }
                    pb.redirectErrorStream(true)
                    if (isStopped) return@launch

                    val p = pb.start()
                    process = p
                    currentPid = extractPid(p)
                    val stdin = p.outputStream
                    stdin.write((command + "\n").toByteArray(Charsets.UTF_8))
                    stdin.flush()

                    notifyState(ServiceState.RUNNING, currentPid)

                    val processStartTime = System.currentTimeMillis()
                    val stdout = p.inputStream
                    stdoutJob?.cancel()
                    stdoutJob = launch {
                        val buffer = ByteArray(4096)
                        var read = 0
                        try {
                            while (isActive && stdout.read(buffer).also { read = it } != -1) {
                                if (read > 0) {
                                    historyBuffer.write(buffer, 0, read)
                                    val frame = packFrame(FRAME_PTY_DATA, buffer, 0, read)
                                    for (client in clients) {
                                        client.enqueueFrame(frame)
                                    }
                                }
                            }
                        } catch (e: IOException) {
                            if (!isStopped) {
                                Log.e(TAG, "$name read error", e)
                            }
                        }

                        if (!isStopped) {
                            if (System.currentTimeMillis() - processStartTime > 60000L) {
                                restartCount = 0
                            }
                            scheduleRestart()
                        }
                    }
                } catch (e: Exception) {
                    if (!isStopped) {
                        Log.e(TAG, "$name start error", e)
                        notifyState(ServiceState.ERROR)
                        scheduleRestart()
                    }
                }
            }
        }

        private fun closeSocketAndClients() {
            acceptJob?.cancel()
            acceptJob = null
            try {
                serverSocket?.close()
            } catch (_: IOException) {}
            serverSocket = null
            for (client in clients) {
                client.close()
            }
            clients.clear()
        }

        private fun scheduleRestart() {
            if (isStopped || restartCount >= 10) {
                val finalState = if (!isStopped && restartCount >= 10) {
                    Log.e(TAG, "$name 连续重启失败已达上限 ($restartCount)，进入 ERROR 终态并关闭监听端口")
                    ServiceState.ERROR
                } else {
                    ServiceState.STOPPED
                }
                notifyState(finalState)
                serviceScope.launch {
                    delay(30)
                    if (currentState == ServiceState.ERROR || isStopped) {
                        closeSocketAndClients()
                    }
                }
                return
            }
            restartJob?.cancel()
            notifyState(ServiceState.RESTARTING)
            val delaySec = minOf(3 * (1 shl restartCount), 60)
            restartCount++
            Log.i(TAG, "$name exited, restarting in ${delaySec}s")
            restartJob = serviceScope.launch {
                delay(delaySec * 1000L)
                if (!isStopped) {
                    start()
                }
            }
        }

        fun isAlive(): Boolean {
            val p = process ?: return false
            if (isStopped) return false
            return isProcessAliveCompat(p)
        }

        suspend fun stop() {
            isStopped = true
            notifyState(ServiceState.STOPPING)
            restartCount = 0
            restartJob?.cancel()
            restartJob = null
            startJob?.cancel()
            startJob = null
            stdoutJob?.cancel()
            stdoutJob = null

            val p = process
            val pid = currentPid
            process = null
            currentPid = -1L

            terminateProcessTree(pid, p)
            notifyState(ServiceState.STOPPED)
            delay(30)
            closeSocketAndClients()
        }
    }
}
