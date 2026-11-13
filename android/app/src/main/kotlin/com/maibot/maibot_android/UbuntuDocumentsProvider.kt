package com.maibot.maibot_android

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Ubuntu 文件系统 DocumentsProvider
 * 将 MaiBot Ubuntu 环境暴露到系统文件管理器
 */
class UbuntuDocumentsProvider : DocumentsProvider() {

    companion object {
        private const val TAG = "UbuntuDocsProvider"
        private const val ROOT_ID = "ubuntu_root"

        // 定义支持的列
        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_MIME_TYPES,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_ICON,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_SUMMARY,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_AVAILABLE_BYTES
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE
        )
    }

    override fun onCreate(): Boolean {
        return true
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val result = MatrixCursor(resolveRootProjection(projection))

        val ubuntuPath = getUbuntuRootPath()
        if (!ubuntuPath.exists()) {
            return result
        }

        val row = result.newRow()
        row.add(DocumentsContract.Root.COLUMN_ROOT_ID, ROOT_ID)
        row.add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, getDocIdForFile(ubuntuPath))
        row.add(DocumentsContract.Root.COLUMN_SUMMARY, "MaiBot Ubuntu 环境")
        row.add(
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
            DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD
        )
        row.add(DocumentsContract.Root.COLUMN_TITLE, "MaiBot Ubuntu")
        row.add(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*")
        row.add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, ubuntuPath.freeSpace)
        row.add(DocumentsContract.Root.COLUMN_ICON, R.mipmap.ic_launcher)

        return result
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val result = MatrixCursor(resolveDocumentProjection(projection))
        includeFile(result, documentId, null)
        return result
    }

    override fun queryChildDocuments(
        parentDocumentId: String?,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val result = MatrixCursor(resolveDocumentProjection(projection))
        if (parentDocumentId == null) return result
        val parent = getFileForDocId(parentDocumentId)

        val files = parent.listFiles()
        if (files != null) {
            for (file in files) {
                // 跳过符号链接指向外部的情况，避免安全检查失败
                try {
                    // 检查是否是有效的子文档
                    val childPath = file.absolutePath
                    var parentPath = parent.absolutePath
                    if (!parentPath.endsWith("/")) {
                        parentPath += "/"
                    }

                    // 只包含真正的子路径
                    if (childPath.startsWith(parentPath) || childPath == parent.absolutePath) {
                        includeFile(result, null, file)
                    }
                } catch (_: Exception) {
                    // 跳过有问题的文件
                    continue
                }
            }
        }
        return result
    }

    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        if (documentId == null) throw FileNotFoundException("documentId is null")
        val file = getFileForDocId(documentId)
        val accessMode = ParcelFileDescriptor.parseMode(mode)
        return ParcelFileDescriptor.open(file, accessMode)
    }

    override fun createDocument(
        parentDocumentId: String?,
        mimeType: String?,
        displayName: String?
    ): String {
        if (parentDocumentId == null || displayName == null) {
            throw FileNotFoundException("parentDocumentId or displayName is null")
        }
        val parent = getFileForDocId(parentDocumentId)
        val file = File(parent, displayName)

        try {
            if (DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                if (!file.mkdir()) {
                    throw FileNotFoundException("Failed to create directory")
                }
            } else {
                if (!file.createNewFile()) {
                    throw FileNotFoundException("Failed to create file")
                }
            }
        } catch (e: Exception) {
            throw FileNotFoundException("Failed to create document: ${e.message}")
        }

        return getDocIdForFile(file)
    }

    override fun deleteDocument(documentId: String?) {
        if (documentId == null) throw FileNotFoundException("documentId is null")
        val file = getFileForDocId(documentId)
        if (!file.deleteRecursively()) {
            throw FileNotFoundException("Failed to delete document")
        }
    }

    override fun renameDocument(documentId: String?, displayName: String?): String {
        if (documentId == null || displayName == null) {
            throw FileNotFoundException("documentId or displayName is null")
        }
        val file = getFileForDocId(documentId)
        val target = File(file.parentFile, displayName)

        if (!file.renameTo(target)) {
            throw FileNotFoundException("Failed to rename document")
        }

        return getDocIdForFile(target)
    }

    /**
     * 获取 Ubuntu 根路径
     */
    private fun getUbuntuRootPath(): File {
        val filesDir = context?.filesDir ?: File("/data/data/com.maibot.maibot_android/files")
        return File(filesDir, "usr/var/lib/proot-distro/installed-rootfs/ubuntu")
    }

    /**
     * 通过文档 ID 获取文件
     */
    private fun getFileForDocId(docId: String): File {
        val target = File(docId)
        try {
            val path = target.canonicalPath
            val rootPath = getUbuntuRootPath().canonicalPath
            if (path != rootPath && !path.startsWith(rootPath + File.separator)) {
                throw FileNotFoundException("Path traversal denied")
            }
        } catch (_: IOException) {
            throw FileNotFoundException("Invalid path")
        }
        if (!target.exists()) {
            throw FileNotFoundException("File not found: $docId")
        }
        return target
    }

    /**
     * 检查文件是否是根目录的子文件
     * 覆盖此方法以正确处理符号链接
     */
    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        if (parentDocumentId == null || documentId == null) return false
        return try {
            val parent = getFileForDocId(parentDocumentId)
            val child = getFileForDocId(documentId)

            // 使用字符串路径比较，而不是 canonical path
            // 这样可以正确处理符号链接
            var parentPath = parent.absolutePath
            val childPath = child.absolutePath

            if (!parentPath.endsWith("/")) {
                parentPath += "/"
            }

            childPath.startsWith(parentPath)
        } catch (_: FileNotFoundException) {
            false
        }
    }

    /**
     * 获取文件的文档 ID（使用绝对路径）
     */
    private fun getDocIdForFile(file: File): String {
        return file.absolutePath
    }

    /**
     * 将文件信息添加到游标
     */
    private fun includeFile(result: MatrixCursor, docId: String?, file: File?) {
        val targetFile = when {
            docId != null -> getFileForDocId(docId)
            file != null -> file
            else -> return
        }
        val targetDocId = docId ?: getDocIdForFile(targetFile)

        var flags = 0

        if (targetFile.isDirectory) {
            if (targetFile.canWrite()) {
                flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
            }
        } else if (targetFile.canWrite()) {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        }

        if (targetFile.canWrite()) {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_RENAME
        }

        val displayName = targetFile.name
        val mimeType = getTypeForFile(targetFile)

        if (mimeType.startsWith("image/")) {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
        }

        val row = result.newRow()
        row.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, targetDocId)
        row.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, displayName)
        row.add(DocumentsContract.Document.COLUMN_SIZE, targetFile.length())
        row.add(DocumentsContract.Document.COLUMN_MIME_TYPE, mimeType)
        row.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, targetFile.lastModified())
        row.add(DocumentsContract.Document.COLUMN_FLAGS, flags)
    }

    /**
     * 根据文件获取 MIME 类型
     */
    private fun getTypeForFile(file: File): String {
        return if (file.isDirectory) {
            DocumentsContract.Document.MIME_TYPE_DIR
        } else {
            val name = file.name
            val lastDot = name.lastIndexOf('.')
            if (lastDot >= 0) {
                val extension = name.substring(lastDot + 1).lowercase()
                val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                if (mime != null) {
                    return mime
                }
            }
            "application/octet-stream"
        }
    }

    private fun resolveRootProjection(projection: Array<out String>?): Array<out String> {
        return projection ?: DEFAULT_ROOT_PROJECTION
    }

    private fun resolveDocumentProjection(projection: Array<out String>?): Array<out String> {
        return projection ?: DEFAULT_DOCUMENT_PROJECTION
    }
}
