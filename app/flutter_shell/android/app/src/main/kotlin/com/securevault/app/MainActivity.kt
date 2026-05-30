package com.securevault.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "secure_vault/platform"

        init {
            System.loadLibrary("crypt_core")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setScreenProtection" -> {
                    val enabled = call.arguments as? Boolean ?: true
                    runOnUiThread {
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                }
                "getInitialOpenPath" -> result.success(resolveIntentToLocalPath(intent))
                "openExternal" -> {
                    val path = call.arguments as? String
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "Path is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = if (path.startsWith("content://")) {
                            Uri.parse(path)
                        } else if (path.startsWith("file://")) {
                            val fileUri = Uri.parse(path)
                            FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                File(fileUri.path ?: path)
                            )
                        } else {
                            FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                File(path)
                            )
                        }
                        val mime = contentResolver.getType(uri) ?: "*/*"
                        val openIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(openIntent, "Open with"))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("open_external_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun resolveIntentToLocalPath(intent: Intent?): String? {
        val uri = intent?.data ?: return null
        return when (uri.scheme) {
            "file" -> uri.path
            "content" -> copyContentUri(uri)
            else -> null
        }
    }

    private fun copyContentUri(uri: Uri): String? {
        val input = contentResolver.openInputStream(uri) ?: return null
        val incomingDir = File(filesDir, "incoming")
        if (!incomingDir.exists()) incomingDir.mkdirs()
        val displayName = safeDisplayName(uri) ?: "incoming-${UUID.randomUUID()}"
        val target = File(incomingDir, sanitizeFileName(displayName))
        input.use { source ->
            FileOutputStream(target).use { output ->
                source.copyTo(output)
            }
        }
        return target.absolutePath
    }

    private fun safeDisplayName(uri: Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                return cursor.getString(nameIndex)
            }
        }
        return uri.lastPathSegment
    }

    private fun sanitizeFileName(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
}
