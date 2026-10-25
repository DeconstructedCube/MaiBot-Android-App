package com.maibot.maibot_android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
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
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

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
class ByteRingBuffer(private val capacity: Int = 65536) {
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
    private var maibotProcess: ProotProcess? = null
    private var napcatProcess: ProotProcess? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MaiBot::BackendLock").apply {
            acquire()
        }
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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
            startForeground(1002, notification)
        } catch (e: Exception) {
            Log.e(TAG, "startForeground error", e)
        }

        val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
        val action = intent?.action
        val userStopped = sp.getBoolean("user_stopped", false)

        if (userStopped && action != "CONTROL" && action != "START") {
            Log.i(TAG, "用户之前已显式退出应用，禁止后台自动唤醒")
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent != null) {
            var binPath = intent.getStringExtra("binPath")
            var homePath = intent.getStringExtra("homePath")
            var tmpPath = intent.getStringExtra("tmpPath")
            var ubuntuPath = intent.getStringExtra("ubuntuPath")

            if (binPath != null && homePath != null) {
                sp.edit()
                    .putString("binPath", binPath)
                    .putString("homePath", homePath)
                    .putString("tmpPath", tmpPath)
                    .putString("ubuntuPath", ubuntuPath)
                    .apply()
            } else {
                val autoStart = sp.getBoolean("auto_start_enabled", true)
                if (!autoStart && action == null) {
                    Log.i(TAG, "自启动已被用户关闭，ProotService 保持待命状态")
                    return START_NOT_STICKY
                }
                binPath = sp.getString("binPath", null) ?: applicationInfo.nativeLibraryDir
                homePath = sp.getString("homePath", null) ?: "${filesDir.absolutePath}/usr"
                tmpPath = sp.getString("tmpPath", null) ?: cacheDir.absolutePath
                ubuntuPath = sp.getString("ubuntuPath", null)
                    ?: "${filesDir.absolutePath}/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
            }

            val curBin = binPath ?: applicationInfo.nativeLibraryDir
            val curHome = homePath ?: "${filesDir.absolutePath}/usr"
            val curTmp = tmpPath ?: cacheDir.absolutePath
            val curUbuntu = ubuntuPath ?: "${filesDir.absolutePath}/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
            val ctrlAction = intent.getStringExtra("action")?.uppercase() ?: "START"
            val ctrlTarget = intent.getStringExtra("target")?.uppercase() ?: "ALL"

            commandChannel.trySend {
                handleCommandAsync(action, ctrlAction, ctrlTarget, curBin, curHome, curTmp, curUbuntu)
            }
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
        curUbuntu: String
    ) {
        val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)

        if ("STOP" == action) {
            sp.edit().putBoolean("user_stopped", true).apply()
            safelyTerminateAllProcesses(curBin, curTmp, curUbuntu)
            stopForegroundAndSelf()
            return
        }

        if ("CONTROL" == action) {
            Log.i(TAG, "收到控制指令: action=$ctrlAction, target=$ctrlTarget")
            when (ctrlAction) {
                "START" -> {
                    sp.edit().putBoolean("user_stopped", false).apply()
                    if (ctrlTarget == "ALL" || ctrlTarget == "MAIBOT") {
                        startMaiBot(curBin, curHome, curTmp, curUbuntu)
                    }
                    if (ctrlTarget == "ALL" || ctrlTarget == "NAPCAT") {
                        startNapCat(curBin, curHome, curTmp, curUbuntu)
                    }
                }
                "STOP" -> {
                    if (ctrlTarget == "MAIBOT") {
                        maibotProcess?.stop()
                    } else if (ctrlTarget == "NAPCAT") {
                        napcatProcess?.stop()
                    } else if (ctrlTarget == "ALL") {
                        sp.edit().putBoolean("user_stopped", true).apply()
                        safelyTerminateAllProcesses(curBin, curTmp, curUbuntu)
                        stopForegroundAndSelf()
                    }
                }
                "RESTART" -> {
                    sp.edit().putBoolean("user_stopped", false).apply()
                    if (ctrlTarget == "MAIBOT") {
                        startMaiBot(curBin, curHome, curTmp, curUbuntu, forceRestart = true)
                    } else if (ctrlTarget == "NAPCAT") {
                        startNapCat(curBin, curHome, curTmp, curUbuntu, forceRestart = true)
                    } else if (ctrlTarget == "ALL") {
                        startMaiBot(curBin, curHome, curTmp, curUbuntu, forceRestart = true)
                        startNapCat(curBin, curHome, curTmp, curUbuntu, forceRestart = true)
                    }
                }
                "SAFE_TERMINATE" -> {
                    safelyTerminateAllProcesses(curBin, curTmp, curUbuntu)
                }
            }
            return
        }

        val rootfsCheck = File(curUbuntu, "bin/bash")
        if (!rootfsCheck.exists()) {
            Log.w(TAG, "Ubuntu RootFS 未就绪 (${rootfsCheck.absolutePath} 不存在)，暂缓启动容器进程")
            return
        }

        startMaiBot(curBin, curHome, curTmp, curUbuntu)
        startNapCat(curBin, curHome, curTmp, curUbuntu)
    }

    private fun stopForegroundAndSelf() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun startMaiBot(binPath: String, homePath: String, tmpPath: String, ubuntuPath: String, forceRestart: Boolean = false) {
        if (!forceRestart && maibotProcess?.isAlive() == true) {
            Log.d(TAG, "MaiBot 进程已在运行，跳过启动")
            return
        }
        maibotProcess?.stop()
        maibotProcess = null

        Log.i(TAG, "启动 MaiBot 服务进程...")
        val maibotCmd = """
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
            export UV_INDEX_URL=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
            export PIP_NO_COLOR=0
            export COLUMNS=45
            export LINES=24
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8
            export UV_LINK_MODE=copy
            export TMPDIR=/tmp
            export TEMP=/tmp
            export TMP=/tmp
            mkdir -p /tmp /var/tmp
            cd /root/MaiBot
            if [ -f EULA.md ]; then export EULA_AGREE=$(md5sum EULA.md | awk '{print $1}'); fi
            if [ -f PRIVACY.md ]; then export PRIVACY_AGREE=$(md5sum PRIVACY.md | awk '{print $1}'); fi
            if command -v script >/dev/null 2>&1; then
                exec script -q -e -c "stty cols 45 rows 24 2>/dev/null; /root/.local/bin/uv run --color always bot.py" /dev/null
            else
                exec /root/.local/bin/uv run --color always bot.py
            fi
        """.trimIndent() + "\n"

        maibotProcess = ProotProcess("MaiBot", 20001, binPath, homePath, tmpPath, ubuntuPath, maibotCmd).apply {
            start()
        }
    }

    private fun startNapCat(binPath: String, homePath: String, tmpPath: String, ubuntuPath: String, forceRestart: Boolean = false) {
        if (!forceRestart && napcatProcess?.isAlive() == true) {
            Log.d(TAG, "NapCat 进程已在运行，跳过启动")
            return
        }
        napcatProcess?.stop()
        napcatProcess = null

        Log.i(TAG, "启动 NapCat 服务进程...")
        cleanNapcatLocks(tmpPath, ubuntuPath)
        val napcatCmd = """
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export TERM=xterm-256color
            export COLORTERM=truecolor
            export FORCE_COLOR=1
            export CLICOLOR_FORCE=1
            export CLICOLOR=1
            export COLUMNS=45
            export LINES=24
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8
            export TMPDIR=/tmp
            export TEMP=/tmp
            export TMP=/tmp
            mkdir -p /tmp /var/tmp /root/.config/QQ
            chmod 777 /tmp /var/tmp 2>/dev/null || true
            rm -rf /tmp/Singleton* /tmp/.org.chromium.* /tmp/QQ* /root/.config/QQ/Singleton* /root/.config/QQ/Crashpad* /root/.config/QQ/QQ* /root/.config/QQ/*lock* 2>/dev/null || true
            cd /root
            if [ -f /root/launcher.sh ]; then
                exec bash /root/launcher.sh
            elif [ -d /root/napcat ]; then
                cd /root/napcat && exec env LD_PRELOAD=./libnapcat_launcher.so qq --no-sandbox
            fi
        """.trimIndent() + "\n"

        napcatProcess = ProotProcess("NapCat", 20002, binPath, homePath, tmpPath, ubuntuPath, napcatCmd).apply {
            start()
        }
    }

    private suspend fun safelyTerminateAllProcesses(binPath: String?, tmpPath: String, ubuntuPath: String) {
        maibotProcess?.stop()
        napcatProcess?.stop()
        if (binPath != null) {
            try {
                Runtime.getRuntime().exec(
                    arrayOf("$binPath/busybox", "killall", "-2", "python", "python3", "node", "qq", "bash", "sh")
                ).waitFor()
            } catch (_: Exception) {}
            delay(500)
            try {
                Runtime.getRuntime().exec(
                    arrayOf(
                        "$binPath/busybox", "killall", "-9",
                        "proot", "qq", "python", "python3", "node", "bash", "sh", "crashpad_handler"
                    )
                ).waitFor()
            } catch (_: Exception) {}
        }
        cleanNapcatLocks(tmpPath, ubuntuPath)
    }

    override fun onDestroy() {
        val sp = getSharedPreferences("maibot_backend_prefs", Context.MODE_PRIVATE)
        val binPath = sp.getString("binPath", null) ?: applicationInfo.nativeLibraryDir
        val tmpPath = sp.getString("tmpPath", null) ?: cacheDir.absolutePath
        val ubuntuPath = sp.getString("ubuntuPath", null)
            ?: "${filesDir.absolutePath}/usr/var/lib/proot-distro/installed-rootfs/ubuntu"

        commandChannel.close()
        runBlocking(Dispatchers.IO) {
            withTimeoutOrNull(1500L) {
                safelyTerminateAllProcesses(binPath, tmpPath, ubuntuPath)
            }
        }
        serviceScope.cancel()

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

    private fun cleanNapcatLocks(tmpPath: String, ubuntuPath: String) {
        try {
            val paths = arrayOf(
                "$tmpPath/SingletonLock",
                "$tmpPath/SingletonSocket",
                "$tmpPath/SingletonCookie",
                "$tmpPath/.X1-lock",
                "$ubuntuPath/tmp/SingletonLock",
                "$ubuntuPath/tmp/SingletonSocket",
                "$ubuntuPath/tmp/SingletonCookie",
                "$ubuntuPath/root/.config/QQ/SingletonLock",
                "$ubuntuPath/root/.config/QQ/SingletonSocket",
                "$ubuntuPath/root/.config/QQ/SingletonCookie"
            )
            for (p in paths) {
                val f = File(p)
                if (f.exists()) f.delete()
            }
        } catch (_: Exception) {}
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
        private val command: String
    ) {
        private var process: Process? = null
        private var serverSocket: ServerSocket? = null
        private val clients = CopyOnWriteArrayList<ClientSession>()
        private val historyBuffer = ByteRingBuffer(65536)

        private var restartCount = 0
        private var restartJob: Job? = null
        private var acceptJob: Job? = null
        private var stdoutJob: Job? = null

        @Volatile
        var isStopped = false

        @Volatile
        var currentState: ServiceState = ServiceState.STOPPED
            private set

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
                        initFrames.add(buildStateFrame(currentState, -1))

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
                notifyState(ServiceState.RUNNING)
                return
            }
            restartJob?.cancel()
            restartJob = null
            notifyState(ServiceState.STARTING)

            serviceScope.launch {
                try {
                    initServerSocket()
                    historyBuffer.clear()

                    val cmd = mutableListOf(
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

                    // Fake sysdata bindings to prevent Python/uv crashes on restricted Android /proc
                    val fakeProcs = arrayOf(
                        ".loadavg", ".stat", ".uptime", ".version", ".vmstat",
                        ".sysctl_entry_cap_last_cap", ".sysctl_inotify_max_user_watches"
                    )
                    val targetProcs = arrayOf(
                        "/proc/loadavg", "/proc/stat", "/proc/uptime", "/proc/version", "/proc/vmstat",
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

                    val pb = ProcessBuilder(cmd)
                    pb.environment().apply {
                        put("PATH", "$binPath:/system/bin:/system/xbin")
                        put("HOME", "/root")
                        put("PROOT_TMP_DIR", tmpPath)
                        put("PROOT_LOADER", "$binPath/loader")
                        put("LD_LIBRARY_PATH", binPath)
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
                        put("UV_INDEX_URL", "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple")
                        put("PIP_NO_COLOR", "0")
                        put("COLUMNS", "45")
                        put("LINES", "24")
                        put("LANG", "C.UTF-8")
                        put("LC_ALL", "C.UTF-8")
                        put("TMPDIR", "/tmp")
                        put("TEMP", "/tmp")
                        put("TMP", "/tmp")
                    }
                    pb.redirectErrorStream(true)
                    val p = pb.start()
                    process = p
                    val stdin = p.outputStream
                    stdin.write((command + "\n").toByteArray(Charsets.UTF_8))
                    stdin.flush()

                    notifyState(ServiceState.RUNNING)

                    val processStartTime = System.currentTimeMillis()
                    val stdout = p.inputStream
                    stdoutJob?.cancel()
                    stdoutJob = launch {
                        val buffer = ByteArray(4096)
                        var read: Int
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
                    Log.e(TAG, "$name start error", e)
                    notifyState(ServiceState.ERROR)
                    scheduleRestart()
                }
            }
        }

        @Synchronized
        private fun scheduleRestart() {
            if (isStopped || restartCount >= 10) {
                notifyState(ServiceState.STOPPED)
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

        @Synchronized
        fun stop() {
            isStopped = true
            notifyState(ServiceState.STOPPING)
            restartCount = 0
            restartJob?.cancel()
            restartJob = null
            acceptJob?.cancel()
            acceptJob = null
            stdoutJob?.cancel()
            stdoutJob = null

            process?.destroy()
            process = null
            try {
                serverSocket?.close()
            } catch (_: IOException) {}
            serverSocket = null

            for (client in clients) {
                client.close()
            }
            clients.clear()
            notifyState(ServiceState.STOPPED)
        }
    }
}
