package com.maibot.maibot_android

import android.content.Context
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.createApplicationPlugin
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.cio.CIOApplicationEngine
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.header
import io.ktor.server.request.path
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.modelcontextprotocol.kotlin.sdk.server.Server
import io.modelcontextprotocol.kotlin.sdk.server.ServerOptions
import io.modelcontextprotocol.kotlin.sdk.server.mcpStreamableHttp
import io.modelcontextprotocol.kotlin.sdk.types.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.types.Implementation
import io.modelcontextprotocol.kotlin.sdk.types.ServerCapabilities
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import io.modelcontextprotocol.kotlin.sdk.types.ToolAnnotations
import io.modelcontextprotocol.kotlin.sdk.types.ToolSchema
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom

data class McpConfig(
    val enabled: Boolean = false,
    val port: Int = 18081,
    val token: String = "",
    val allowWrite: Boolean = false,
    val allowExec: Boolean = false,
    val allowServiceControl: Boolean = true,
    val rootScope: String = "maibot", // "maibot" | "ubuntu"
    val protectSecrets: Boolean = true
)

data class McpRuntimeStatus(
    val running: Boolean = false,
    val boundPort: Int = 0,
    val lastError: String = "",
    val requestCount: Long = 0L,
    val lastToolName: String = "",
    val lastToolAtMs: Long = 0L
)

object McpPrefsStore {
    private val rng = SecureRandom()

    private fun prefDir(context: Context): File = File(context.filesDir, ".backend_prefs").apply {
        if (!exists()) mkdirs()
    }

    fun generateToken(byteLength: Int = 32): String {
        val bytes = ByteArray(byteLength)
        rng.nextBytes(bytes)
        val sb = StringBuilder(byteLength * 2)
        for (b in bytes) {
            sb.append(String.format("%02x", b))
        }
        return sb.toString()
    }

    private fun writeAtomic(file: File, content: String) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(content, StandardCharsets.UTF_8)
        if (file.exists()) {
            file.delete()
        }
        if (!tmp.renameTo(file)) {
            file.writeText(content, StandardCharsets.UTF_8)
            tmp.delete()
        }
    }

    @Synchronized
    fun loadConfig(context: Context): McpConfig {
        val file = File(prefDir(context), "mcp_config.json")
        if (!file.exists()) {
            val initial = McpConfig(token = generateToken())
            saveConfig(context, initial)
            return initial
        }
        return try {
            val obj = JSONObject(file.readText(StandardCharsets.UTF_8))
            var token = obj.optString("token", "").trim()
            var needsSave = false
            if (token.isEmpty()) {
                token = generateToken()
                needsSave = true
            }
            val rawPort = obj.optInt("port", 18081)
            val port = if (rawPort in 1024..65535) rawPort else 18081
            val scope = obj.optString("rootScope", "maibot").let {
                if (it == "ubuntu") "ubuntu" else "maibot"
            }
            val cfg = McpConfig(
                enabled = obj.optBoolean("enabled", false),
                port = port,
                token = token,
                allowWrite = obj.optBoolean("allowWrite", false),
                allowExec = obj.optBoolean("allowExec", false),
                allowServiceControl = obj.optBoolean("allowServiceControl", true),
                rootScope = scope,
                protectSecrets = obj.optBoolean("protectSecrets", true)
            )
            if (needsSave) saveConfig(context, cfg)
            cfg
        } catch (_: Exception) {
            val fallback = McpConfig(token = generateToken())
            saveConfig(context, fallback)
            fallback
        }
    }

    @Synchronized
    fun saveConfig(context: Context, config: McpConfig) {
        val safePort = if (config.port in 1024..65535) config.port else 18081
        val safeToken = config.token.trim().ifEmpty { generateToken() }
        val safeScope = if (config.rootScope == "ubuntu") "ubuntu" else "maibot"
        val obj = JSONObject().apply {
            put("enabled", config.enabled)
            put("port", safePort)
            put("token", safeToken)
            put("allowWrite", config.allowWrite)
            put("allowExec", config.allowExec)
            put("allowServiceControl", config.allowServiceControl)
            put("rootScope", safeScope)
            put("protectSecrets", config.protectSecrets)
        }
        writeAtomic(File(prefDir(context), "mcp_config.json"), obj.toString(2))
    }

    @Synchronized
    fun resetToken(context: Context): McpConfig {
        val cur = loadConfig(context)
        val updated = cur.copy(token = generateToken())
        saveConfig(context, updated)
        return updated
    }

    @Synchronized
    fun saveStatus(context: Context, status: McpRuntimeStatus) {
        val obj = JSONObject().apply {
            put("running", status.running)
            put("boundPort", status.boundPort)
            put("lastError", status.lastError)
            put("requestCount", status.requestCount)
            put("lastToolName", status.lastToolName)
            put("lastToolAtMs", status.lastToolAtMs)
        }
        writeAtomic(File(prefDir(context), "mcp_status.json"), obj.toString())
    }

    @Synchronized
    fun loadStatus(context: Context): McpRuntimeStatus {
        val file = File(prefDir(context), "mcp_status.json")
        if (!file.exists()) return McpRuntimeStatus()
        return try {
            val obj = JSONObject(file.readText(StandardCharsets.UTF_8))
            McpRuntimeStatus(
                running = obj.optBoolean("running", false),
                boundPort = obj.optInt("boundPort", 0),
                lastError = obj.optString("lastError", ""),
                requestCount = obj.optLong("requestCount", 0L),
                lastToolName = obj.optString("lastToolName", ""),
                lastToolAtMs = obj.optLong("lastToolAtMs", 0L)
            )
        } catch (_: Exception) {
            McpRuntimeStatus()
        }
    }
}

interface McpHostBridge {
    fun getPaths(): ContainerPaths
    fun getServiceSnapshotJson(): JSONObject
    fun getLiveLogBytes(): ByteArray
    suspend fun controlService(action: String): String
    suspend fun cleanStaleLocks(): Int

    data class ContainerPaths(
        val binPath: String,
        val homePath: String,
        val tmpPath: String,
        val ubuntuPath: String
    )
}

class McpBackendServer(
    private val context: Context,
    private val scope: CoroutineScope,
    private val hostBridge: McpHostBridge
) {
    private var engine: EmbeddedServer<CIOApplicationEngine, CIOApplicationEngine.Configuration>? = null
    private var currentBoundPort: Int = 0
    private val requestCounter = AtomicLong(0L)
    @Volatile
    private var lastToolName: String = ""
    @Volatile
    private var lastToolAtMs: Long = 0L

    @Synchronized
    fun isRunning(): Boolean = engine != null

    @Synchronized
    fun applyConfig(config: McpConfig) {
        if (!config.enabled) {
            stop()
            return
        }
        if (engine != null && currentBoundPort == config.port) {
            // Token/permission flags are read dynamically from McpPrefsStore on every request.
            publishStatus(running = true, port = currentBoundPort, lastError = "")
            return
        }
        stop()
        start(config)
    }

    @Synchronized
    private fun start(config: McpConfig) {
        try {
            val server = scope.embeddedServer(
                factory = CIO,
                port = config.port,
                host = "127.0.0.1",
                watchPaths = emptyList()
            ) {
                configureApplication(this)
            }
            server.start(wait = false)
            engine = server
            currentBoundPort = config.port
            publishStatus(running = true, port = config.port, lastError = "")
        } catch (e: Exception) {
            engine = null
            currentBoundPort = 0
            publishStatus(running = false, port = 0, lastError = e.message ?: e.javaClass.simpleName)
        }
    }

    @Synchronized
    fun stop() {
        val runningEngine = engine
        engine = null
        currentBoundPort = 0
        if (runningEngine != null) {
            try {
                runningEngine.stop(300L, 1200L)
            } catch (_: Exception) {}
        }
        publishStatus(running = false, port = 0, lastError = "")
    }

    private fun publishStatus(running: Boolean, port: Int, lastError: String) {
        McpPrefsStore.saveStatus(
            context,
            McpRuntimeStatus(
                running = running,
                boundPort = port,
                lastError = lastError,
                requestCount = requestCounter.get(),
                lastToolName = lastToolName,
                lastToolAtMs = lastToolAtMs
            )
        )
    }

    private fun recordToolCall(toolName: String) {
        requestCounter.incrementAndGet()
        lastToolName = toolName
        lastToolAtMs = System.currentTimeMillis()
        publishStatus(running = engine != null, port = currentBoundPort, lastError = "")
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        return MessageDigest.isEqual(
            a.toByteArray(StandardCharsets.UTF_8),
            b.toByteArray(StandardCharsets.UTF_8)
        )
    }

    private fun configureApplication(app: Application) {
        val bearerAuth = createApplicationPlugin("McpBearerAuth") {
            onCall { call ->
                if (call.request.path() == "/health") return@onCall
                val cfg = McpPrefsStore.loadConfig(context)
                val expected = "Bearer ${cfg.token}"
                val provided = call.request.header(HttpHeaders.Authorization)
                if (provided == null || !constantTimeEquals(provided, expected)) {
                    call.respondText(
                        """{"error":"Unauthorized: invalid or missing Bearer token"}""",
                        ContentType.Application.Json,
                        HttpStatusCode.Unauthorized
                    )
                }
            }
        }
        app.install(bearerAuth)

        app.routing {
            get("/health") {
                call.respondText(
                    """{"ok":true,"service":"maibot-android-mcp"}""",
                    ContentType.Application.Json
                )
            }
        }

        app.mcpStreamableHttp(
            path = "/mcp",
            enableDnsRebindingProtection = true
        ) {
            buildMcpServer()
        }
    }

    private fun buildMcpServer(): Server {
        val server = Server(
            serverInfo = Implementation(
                name = "maibot-android-mcp",
                version = "1.0.0",
                title = "MaiBot Android Backend MCP"
            ),
            options = ServerOptions(
                capabilities = ServerCapabilities(
                    tools = ServerCapabilities.Tools(listChanged = false)
                )
            ),
            instructions = "MaiBot Android :backend MCP server for container inspection, file access, logs, PRoot shell execution, and service control."
        )

        registerTools(server)
        return server
    }

    private fun mcpOk(text: String): CallToolResult =
        CallToolResult(content = listOf(TextContent(text)), isError = false)

    private fun mcpErr(text: String): CallToolResult =
        CallToolResult(content = listOf(TextContent(text)), isError = true)

    private fun JsonObject?.strArg(key: String): String? =
        this?.get(key)?.jsonPrimitive?.contentOrNull

    private fun JsonObject?.intArg(key: String): Int? =
        this?.get(key)?.jsonPrimitive?.intOrNull

    private fun JsonObject?.boolArg(key: String): Boolean? =
        this?.get(key)?.jsonPrimitive?.booleanOrNull

    private fun resolveAllowedRoot(cfg: McpConfig): File {
        val ubuntu = File(hostBridge.getPaths().ubuntuPath)
        return if (cfg.rootScope == "ubuntu") ubuntu else File(ubuntu, "root/MaiBot")
    }

    private fun isSecretPath(ubuntuRoot: File, targetCanonical: String): Boolean {
        val maibotRoot = File(ubuntuRoot, "root/MaiBot").canonicalPath
        val rel = if (targetCanonical.startsWith("$maibotRoot${File.separator}")) {
            targetCanonical.substring(maibotRoot.length + 1).replace(File.separatorChar, '/')
        } else {
            return false
        }
        return rel == "host/webui.json" ||
            rel == "host/sessions.sqlite3" ||
            rel == "host/sessions.sqlite3-wal" ||
            rel == "host/sessions.sqlite3-shm" ||
            rel == "data/webui.json"
    }

    private fun resolveSandboxPath(cfg: McpConfig, rawPath: String?): Result<File> {
        val ubuntuRoot = File(hostBridge.getPaths().ubuntuPath)
        val allowedRoot = resolveAllowedRoot(cfg)
        val rootCanonical = try {
            allowedRoot.canonicalFile
        } catch (e: Exception) {
            return Result.failure(IllegalStateException("Root directory unavailable: ${e.message}"))
        }

        val cleaned = (rawPath ?: "").trim().ifEmpty { "." }
        val candidate = if (cleaned.startsWith("/")) {
            // Treat container-absolute paths (e.g. /root/MaiBot/...) cleanly
            val ubuntuRelative = cleaned.removePrefix("/")
            File(ubuntuRoot, ubuntuRelative)
        } else {
            File(allowedRoot, cleaned)
        }

        val resolved = try {
            // For non-existent files (write), canonicalize the nearest existing ancestor + remaining path
            if (candidate.exists()) {
                candidate.canonicalFile
            } else {
                var probe: File? = candidate.parentFile
                val tail = ArrayDeque<String>()
                tail.addFirst(candidate.name)
                while (probe != null && !probe.exists()) {
                    tail.addFirst(probe.name)
                    probe = probe.parentFile
                }
                val baseCanonical = (probe ?: allowedRoot).canonicalFile
                var acc = baseCanonical
                for (seg in tail) {
                    if (seg == "..") {
                        acc = acc.parentFile ?: acc
                    } else if (seg.isNotEmpty() && seg != ".") {
                        acc = File(acc, seg)
                    }
                }
                acc
            }
        } catch (e: Exception) {
            return Result.failure(IllegalArgumentException("Invalid path: ${e.message}"))
        }

        val rootPath = rootCanonical.path
        val targetPath = resolved.path
        if (targetPath != rootPath && !targetPath.startsWith("$rootPath${File.separator}")) {
            return Result.failure(SecurityException("Path escapes allowed root ($rootPath): $rawPath"))
        }
        if (cfg.protectSecrets && isSecretPath(ubuntuRoot, targetPath)) {
            return Result.failure(SecurityException("Access denied by protectSecrets policy: $rawPath"))
        }
        return Result.success(resolved)
    }

    private fun registerTools(server: Server) {
        server.addTool(
            name = "service_status",
            description = "Get MaiBot daemon state, PID, WebUI port, workspace layout, and MCP permissions.",
            inputSchema = ToolSchema(properties = buildJsonObject {}),
            toolAnnotations = ToolAnnotations(readOnlyHint = true)
        ) { _ ->
            recordToolCall("service_status")
            val cfg = McpPrefsStore.loadConfig(context)
            val snapshot = hostBridge.getServiceSnapshotJson()
            val ubuntuRoot = File(hostBridge.getPaths().ubuntuPath)
            val maibotRoot = File(ubuntuRoot, "root/MaiBot")
            val hostConfig = File(maibotRoot, "host/config.toml")
            var webPort = 8001
            if (hostConfig.exists()) {
                val match = Regex("""^\s*port\s*=\s*(\d{2,5})\b""", RegexOption.MULTILINE)
                    .find(hostConfig.readText(StandardCharsets.UTF_8))
                match?.groupValues?.getOrNull(1)?.toIntOrNull()?.let {
                    if (it in 1..65535) webPort = it
                }
            }
            snapshot.put("webPort", webPort)
            snapshot.put("maibotInstalled", File(maibotRoot, "bot.py").exists())
            snapshot.put("mcp", JSONObject().apply {
                put("port", cfg.port)
                put("rootScope", cfg.rootScope)
                put("allowWrite", cfg.allowWrite)
                put("allowExec", cfg.allowExec)
                put("allowServiceControl", cfg.allowServiceControl)
                put("protectSecrets", cfg.protectSecrets)
            })
            mcpOk(snapshot.toString(2))
        }

        server.addTool(
            name = "logs_tail",
            description = "Read recent MaiBot PTY console logs (default) or a bot/root log file.",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("lines", buildJsonObject {
                        put("type", "integer")
                        put("description", "Max trailing lines to return (1..500, default 120)")
                    })
                    put("stripAnsi", buildJsonObject {
                        put("type", "boolean")
                        put("description", "Strip ANSI color escape codes (default true)")
                    })
                    put("file", buildJsonObject {
                        put("type", "string")
                        put("description", "Optional relative log path under MaiBot, e.g. bots/<id>/temp/worker-console.log")
                    })
                }
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = true)
        ) { req ->
            recordToolCall("logs_tail")
            val lines = (req.arguments.intArg("lines") ?: 120).coerceIn(1, 500)
            val stripAnsi = req.arguments.boolArg("stripAnsi") ?: true
            val fileArg = req.arguments.strArg("file")?.trim()

            val rawText = if (!fileArg.isNullOrEmpty()) {
                val cfg = McpPrefsStore.loadConfig(context)
                val target = resolveSandboxPath(cfg, fileArg).getOrElse {
                    return@addTool mcpErr(it.message ?: "Invalid log file path")
                }
                if (!target.exists() || !target.isFile) {
                    return@addTool mcpErr("Log file not found: $fileArg")
                }
                val bytes = target.length()
                if (bytes > 512 * 1024) {
                    target.inputStream().use { ins ->
                        ins.skip(bytes - 512 * 1024)
                        String(ins.readBytes(), StandardCharsets.UTF_8)
                    }
                } else {
                    target.readText(StandardCharsets.UTF_8)
                }
            } else {
                String(hostBridge.getLiveLogBytes(), StandardCharsets.UTF_8)
            }

            val cleaned = if (stripAnsi) {
                rawText.replace(Regex("""\x1B\[[0-?]*[ -/]*[@-~]"""), "")
            } else {
                rawText
            }
            val splitLines = cleaned.replace("\r\n", "\n").replace("\r", "\n").split("\n")
            val tail = splitLines.takeLast(lines).joinToString("\n")
            mcpOk(tail)
        }

        server.addTool(
            name = "fs_list",
            description = "List files and directories under the configured container root.",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("path", buildJsonObject {
                        put("type", "string")
                        put("description", "Relative path (from rootScope) or container-absolute path (e.g. /root/MaiBot/bots)")
                    })
                    put("recursive", buildJsonObject {
                        put("type", "boolean")
                        put("description", "List recursively (default false)")
                    })
                    put("maxEntries", buildJsonObject {
                        put("type", "integer")
                        put("description", "Max entries to return (1..500, default 200)")
                    })
                }
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = true)
        ) { req ->
            recordToolCall("fs_list")
            val cfg = McpPrefsStore.loadConfig(context)
            val dir = resolveSandboxPath(cfg, req.arguments.strArg("path")).getOrElse {
                return@addTool mcpErr(it.message ?: "Invalid path")
            }
            if (!dir.exists()) return@addTool mcpErr("Directory does not exist: ${dir.path}")
            if (!dir.isDirectory) return@addTool mcpErr("Not a directory: ${dir.path}")
            val recursive = req.arguments.boolArg("recursive") ?: false
            val maxEntries = (req.arguments.intArg("maxEntries") ?: 200).coerceIn(1, 500)
            val arr = JSONArray()
            val rootPrefix = dir.path.trimEnd(File.separatorChar) + File.separatorChar

            fun visit(current: File) {
                val children = current.listFiles()?.sortedWith(compareBy({ !it.isDirectory }, { it.name })) ?: return
                for (child in children) {
                    if (arr.length() >= maxEntries) return
                    if (child.name == ".venv" || child.name == "__pycache__" || child.name == ".git") {
                        if (recursive) continue
                    }
                    val rel = child.path.removePrefix(rootPrefix)
                    arr.put(JSONObject().apply {
                        put("name", child.name)
                        put("path", rel)
                        put("type", if (child.isDirectory) "dir" else "file")
                        if (child.isFile) put("size", child.length())
                        put("mtime", child.lastModified())
                    })
                    if (recursive && child.isDirectory && arr.length() < maxEntries) {
                        visit(child)
                    }
                }
            }

            withContext(Dispatchers.IO) { visit(dir) }
            mcpOk(arr.toString(2))
        }

        server.addTool(
            name = "fs_read",
            description = "Read UTF-8 text file inside the allowed container root (with optional line range).",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("path", buildJsonObject {
                        put("type", "string")
                        put("description", "File path relative to rootScope or container-absolute")
                    })
                    put("offsetLine", buildJsonObject {
                        put("type", "integer")
                        put("description", "1-based start line (optional)")
                    })
                    put("limitLines", buildJsonObject {
                        put("type", "integer")
                        put("description", "Max lines to read (optional, default 400, max 2000)")
                    })
                },
                required = listOf("path")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = true)
        ) { req ->
            recordToolCall("fs_read")
            val cfg = McpPrefsStore.loadConfig(context)
            val file = resolveSandboxPath(cfg, req.arguments.strArg("path")).getOrElse {
                return@addTool mcpErr(it.message ?: "Invalid path")
            }
            if (!file.exists() || !file.isFile) {
                return@addTool mcpErr("File not found: ${req.arguments.strArg("path")}")
            }
            if (file.length() > 2 * 1024 * 1024 && req.arguments.intArg("offsetLine") == null) {
                return@addTool mcpErr("File larger than 2MB; specify offsetLine and limitLines")
            }

            val startLine = (req.arguments.intArg("offsetLine") ?: 1).coerceAtLeast(1)
            val limit = (req.arguments.intArg("limitLines") ?: 400).coerceIn(1, 2000)

            val resultText = withContext(Dispatchers.IO) {
                val sb = StringBuilder()
                var lineNo = 0
                var collected = 0
                file.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        lineNo++
                        if (lineNo < startLine) continue
                        if (collected >= limit || sb.length >= 256 * 1024) {
                            sb.append("\n... [truncated at line ").append(lineNo - 1).append(']')
                            break
                        }
                        if (collected > 0) sb.append('\n')
                        sb.append(lineNo).append(": ").append(line)
                        collected++
                    }
                }
                sb.toString()
            }
            mcpOk(resultText)
        }

        server.addTool(
            name = "fs_search",
            description = "Search text or regex across files under the allowed container root.",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("pattern", buildJsonObject {
                        put("type", "string")
                        put("description", "Regex or literal search pattern")
                    })
                    put("path", buildJsonObject {
                        put("type", "string")
                        put("description", "Subdirectory or file path (optional, defaults to root)")
                    })
                    put("maxMatches", buildJsonObject {
                        put("type", "integer")
                        put("description", "Max matches (1..200, default 50)")
                    })
                },
                required = listOf("pattern")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = true)
        ) { req ->
            recordToolCall("fs_search")
            val patternStr = req.arguments.strArg("pattern")
            if (patternStr.isNullOrEmpty()) {
                return@addTool mcpErr("pattern is required")
            }
            val regex = try {
                Regex(patternStr)
            } catch (e: Exception) {
                return@addTool mcpErr("Invalid regex: ${e.message}")
            }

            val cfg = McpPrefsStore.loadConfig(context)
            val root = resolveSandboxPath(cfg, req.arguments.strArg("path")).getOrElse {
                return@addTool mcpErr(it.message ?: "Invalid path")
            }
            if (!root.exists()) return@addTool mcpErr("Path not found: ${root.path}")
            val maxMatches = (req.arguments.intArg("maxMatches") ?: 50).coerceIn(1, 200)
            val ubuntuRoot = File(hostBridge.getPaths().ubuntuPath)
            val basePrefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
            val matches = StringBuilder()
            var count = 0

            withContext(Dispatchers.IO) {
                fun scan(f: File) {
                    if (count >= maxMatches) return
                    if (f.isDirectory) {
                        val name = f.name
                        if (name == ".venv" || name == ".git" || name == "__pycache__" || name == "node_modules") return
                        f.listFiles()?.forEach { scan(it) }
                        return
                    }
                    if (!f.isFile || f.length() > 1024 * 1024) return
                    val canonical = runCatching { f.canonicalPath }.getOrNull() ?: return
                    if (cfg.protectSecrets && isSecretPath(ubuntuRoot, canonical)) return
                    val lower = f.name.lowercase()
                    if (lower.endsWith(".sqlite3") || lower.endsWith(".db") || lower.endsWith(".png") ||
                        lower.endsWith(".jpg") || lower.endsWith(".tar.gz") || lower.endsWith(".so")
                    ) return

                    try {
                        var lineNo = 0
                        f.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                            while (count < maxMatches) {
                                val line = reader.readLine() ?: break
                                lineNo++
                                if (regex.containsMatchIn(line)) {
                                    val rel = if (f.path == root.path) f.name else f.path.removePrefix(basePrefix)
                                    matches.append(rel).append(':').append(lineNo).append(": ")
                                        .append(line.take(300)).append('\n')
                                    count++
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
                scan(root)
            }

            mcpOk(if (count == 0) "No matches found." else matches.toString())
        }

        server.addTool(
            name = "fs_write",
            description = "Write or append text to a file inside the allowed container root (requires allowWrite).",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("path", buildJsonObject { put("type", "string") })
                    put("content", buildJsonObject { put("type", "string") })
                    put("append", buildJsonObject { put("type", "boolean") })
                },
                required = listOf("path", "content")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = false, destructiveHint = false)
        ) { req ->
            recordToolCall("fs_write")
            val cfg = McpPrefsStore.loadConfig(context)
            if (!cfg.allowWrite) {
                return@addTool mcpErr("Write operations are disabled in MCP settings (allowWrite=false)")
            }
            val content = req.arguments.strArg("content")
                ?: return@addTool mcpErr("content is required")
            val append = req.arguments.boolArg("append") ?: false
            val target = resolveSandboxPath(cfg, req.arguments.strArg("path")).getOrElse {
                return@addTool mcpErr(it.message ?: "Invalid path")
            }

            withContext(Dispatchers.IO) {
                target.parentFile?.mkdirs()
                if (append) {
                    target.appendText(content, StandardCharsets.UTF_8)
                } else {
                    target.writeText(content, StandardCharsets.UTF_8)
                }
            }
            mcpOk("Wrote ${content.toByteArray(StandardCharsets.UTF_8).size} bytes to ${target.path}")
        }

        server.addTool(
            name = "fs_delete",
            description = "Delete a file or directory inside the allowed container root (requires allowWrite).",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("path", buildJsonObject { put("type", "string") })
                },
                required = listOf("path")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = false, destructiveHint = true)
        ) { req ->
            recordToolCall("fs_delete")
            val cfg = McpPrefsStore.loadConfig(context)
            if (!cfg.allowWrite) {
                return@addTool mcpErr("Write/delete operations are disabled in MCP settings (allowWrite=false)")
            }
            val target = resolveSandboxPath(cfg, req.arguments.strArg("path")).getOrElse {
                return@addTool mcpErr(it.message ?: "Invalid path")
            }
            val rootCanonical = resolveAllowedRoot(cfg).canonicalFile
            if (target.canonicalFile == rootCanonical) {
                return@addTool mcpErr("Refusing to delete allowed root directory itself")
            }
            if (!target.exists()) {
                return@addTool mcpErr("Target does not exist: ${target.path}")
            }
            val deleted = withContext(Dispatchers.IO) { target.deleteRecursively() }
            if (deleted) {
                mcpOk("Deleted: ${target.path}")
            } else {
                mcpErr("Failed to delete: ${target.path}")
            }
        }

        server.addTool(
            name = "proot_exec",
            description = "Execute a single shell command inside the Ubuntu PRoot container (requires allowExec).",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("command", buildJsonObject { put("type", "string") })
                    put("workingDir", buildJsonObject {
                        put("type", "string")
                        put("description", "Container working directory (default /root/MaiBot)")
                    })
                    put("timeoutSec", buildJsonObject {
                        put("type", "integer")
                        put("description", "Timeout in seconds (1..120, default 30)")
                    })
                },
                required = listOf("command")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = false, destructiveHint = true)
        ) { req ->
            recordToolCall("proot_exec")
            val cfg = McpPrefsStore.loadConfig(context)
            if (!cfg.allowExec) {
                return@addTool mcpErr("Shell execution is disabled in MCP settings (allowExec=false)")
            }
            val command = req.arguments.strArg("command")?.trim()
            if (command.isNullOrEmpty()) {
                return@addTool mcpErr("command is required")
            }
            val workDir = req.arguments.strArg("workingDir")?.trim().takeIf { !it.isNullOrEmpty() } ?: "/root/MaiBot"
            val timeoutSec = (req.arguments.intArg("timeoutSec") ?: 30).coerceIn(1, 120)

            val result = withContext(Dispatchers.IO) {
                runProotCommand(command, workDir, timeoutSec)
            }
            CallToolResult(
                content = listOf(
                    TextContent(result.output)
                ),
                isError = !result.success
            )
        }

        server.addTool(
            name = "service_control",
            description = "Start, stop, or restart the MaiBot daemon process (requires allowServiceControl).",
            inputSchema = ToolSchema(
                properties = buildJsonObject {
                    put("action", buildJsonObject {
                        put("type", "string")
                        put("description", "One of: start, stop, restart")
                    })
                },
                required = listOf("action")
            ),
            toolAnnotations = ToolAnnotations(readOnlyHint = false, destructiveHint = false)
        ) { req ->
            recordToolCall("service_control")
            val cfg = McpPrefsStore.loadConfig(context)
            if (!cfg.allowServiceControl) {
                return@addTool mcpErr("Service control is disabled in MCP settings (allowServiceControl=false)")
            }
            val action = req.arguments.strArg("action")?.lowercase()?.trim()
            if (action !in setOf("start", "stop", "restart")) {
                return@addTool mcpErr("Invalid action: $action (expected start, stop, or restart)")
            }
            val message = hostBridge.controlService(action!!)
            mcpOk(message)
        }

        server.addTool(
            name = "rescue_clean_locks",
            description = "Terminate orphan MaiBot workers and remove stale .lock, control.json, and UDS .sock artifacts (requires allowServiceControl).",
            inputSchema = ToolSchema(properties = buildJsonObject {}),
            toolAnnotations = ToolAnnotations(readOnlyHint = false, destructiveHint = true)
        ) { _ ->
            recordToolCall("rescue_clean_locks")
            val cfg = McpPrefsStore.loadConfig(context)
            if (!cfg.allowServiceControl) {
                return@addTool mcpErr("Service control is disabled in MCP settings (allowServiceControl=false)")
            }
            val removed = hostBridge.cleanStaleLocks()
            mcpOk("Cleaned $removed stale runtime lock/socket artifacts.")
        }
    }

    private data class ProotResult(val success: Boolean, val output: String)

    private suspend fun runProotCommand(command: String, workingDir: String, timeoutSec: Int): ProotResult {
        val paths = hostBridge.getPaths()
        val prootBin = File(paths.binPath, "proot")
        if (!prootBin.exists()) {
            return ProotResult(false, "proot binary not found at ${prootBin.absolutePath}")
        }
        File(paths.tmpPath).mkdirs()

        val cmd = mutableListOf(
            prootBin.absolutePath,
            "-0",
            "-r", paths.ubuntuPath,
            "--link2symlink",
            "-b", "/dev",
            "-b", "/proc",
            "-b", "/sys",
            "-b", "${paths.tmpPath}:/tmp",
            "-b", "${paths.tmpPath}:/dev/shm"
        )

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
            val fakeFile = File("${paths.ubuntuPath}/proc/${fakeProcs[i]}")
            if (fakeFile.exists()) {
                cmd.add("-b")
                cmd.add("${fakeFile.absolutePath}:${targetProcs[i]}")
            }
        }

        val safeWorkDir = workingDir.replace("'", "'\\''")
        val wrappedCmd = "export PATH=/root/.local/bin:/root/MaiBot/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; " +
            "cd '$safeWorkDir' 2>/dev/null || cd /root; $command"
        cmd.addAll(listOf("-w", workingDir, "/bin/sh", "-c", wrappedCmd))

        val pb = ProcessBuilder(cmd)
        pb.environment().apply {
            put("PROOT_TMP_DIR", paths.tmpPath)
            put("LD_LIBRARY_PATH", paths.binPath)
            put("PROOT_LOADER", "${paths.binPath}/loader")
            put("MAIBOT_PROC_ROLE", "mcp_exec")
            put("LANG", "C.UTF-8")
            put("LC_ALL", "C.UTF-8")
            put("DEBIAN_FRONTEND", "noninteractive")
            put("GIT_TERMINAL_PROMPT", "0")
            put("TMPDIR", "/tmp")
            put("TEMP", "/tmp")
            put("TMP", "/tmp")
        }
        pb.redirectErrorStream(true)

        val proc = pb.start()
        val outputSb = StringBuilder()
        val readerThread = Thread {
            try {
                val buf = CharArray(4096)
                proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (true) {
                        val n = reader.read(buf)
                        if (n == -1) break
                        synchronized(outputSb) {
                            if (outputSb.length < 128 * 1024) {
                                outputSb.append(buf, 0, n)
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
        }.apply { start() }

        val deadlineMs = System.currentTimeMillis() + timeoutSec * 1000L
        var exitCode: Int? = null
        while (System.currentTimeMillis() < deadlineMs) {
            try {
                exitCode = proc.exitValue()
                break
            } catch (_: IllegalThreadStateException) {
                delay(50)
            }
        }

        if (exitCode == null) {
            proc.destroyForcibly()
            readerThread.join(300L)
            return ProotResult(false, "Command timed out after ${timeoutSec}s\n$outputSb")
        }

        readerThread.join(500L)
        return ProotResult(
            success = exitCode == 0,
            output = "exitCode=$exitCode\n$outputSb"
        )
    }
}
