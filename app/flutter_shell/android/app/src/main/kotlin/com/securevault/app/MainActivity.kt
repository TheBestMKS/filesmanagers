package com.securevault.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.graphics.pdf.PdfRenderer
import android.provider.OpenableColumns
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "secure_vault/platform"
        private const val STORAGE_PERMISSION_REQUEST = 7301

        init {
            System.loadLibrary("crypt_core")
        }
    }

    private var textToSpeech: TextToSpeech? = null

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
                "setPrivacyHints" -> {
                    // Android does not allow a normal file manager to revoke camera or
                    // microphone globally for other apps. The folder policy is accepted
                    // here so Android builds can enforce available in-app protections
                    // without failing the call.
                    result.success(null)
                }
                "getInitialOpenPath" -> result.success(resolveIntentToLocalPath(intent))
                "storageAccessStatus" -> result.success(storageAccessStatus())
                "requestStorageAccess" -> {
                    requestStorageAccess()
                    result.success(null)
                }
                "readMediaArtwork" -> {
                    val path = call.arguments as? String
                    result.success(if (path.isNullOrBlank()) null else readMediaArtwork(path))
                }
                "readVideoThumbnail" -> {
                    val path = call.arguments as? String
                    result.success(if (path.isNullOrBlank()) null else readVideoThumbnail(path))
                }
                "renderPdfFirstPage" -> {
                    val path = call.arguments as? String
                    result.success(if (path.isNullOrBlank()) null else renderPdfFirstPage(path))
                }
                "speakText" -> {
                    val text = call.arguments as? String
                    if (text.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        speakText(text)
                        result.success(null)
                    }
                }
                "openExternal" -> {
                    val path = call.arguments as? String
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "Path is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (path.startsWith("http://") || path.startsWith("https://") || path.startsWith("mailto:")) {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(path)))
                            result.success(null)
                            return@setMethodCallHandler
                        }
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

    override fun onDestroy() {
        try {
            textToSpeech?.stop()
            textToSpeech?.shutdown()
        } catch (_: Exception) {
        }
        textToSpeech = null
        super.onDestroy()
    }

    private fun resolveIntentToLocalPath(intent: Intent?): String? {
        val uri = intent?.data ?: return null
        return when (uri.scheme) {
            "file" -> uri.path
            "content" -> copyContentUri(uri)
            else -> null
        }
    }

    private fun storageAccessStatus(): Map<String, Any> =
        mapOf(
            "isAndroid" to true,
            "sdkInt" to Build.VERSION.SDK_INT,
            "hasAllFilesAccess" to hasAllFilesAccess(),
            "hasMediaImages" to hasPermissionFor(Manifest.permission.READ_MEDIA_IMAGES, 33),
            "hasMediaVideo" to hasPermissionFor(Manifest.permission.READ_MEDIA_VIDEO, 33),
            "hasMediaAudio" to hasPermissionFor(Manifest.permission.READ_MEDIA_AUDIO, 33),
        )

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun hasPermissionFor(permission: String, minSdk: Int): Boolean =
        if (Build.VERSION.SDK_INT >= minSdk) {
            hasPermission(permission)
        } else {
            hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun requestStorageAccess() {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) {
            if (!hasPermission(Manifest.permission.READ_MEDIA_IMAGES)) {
                permissions.add(Manifest.permission.READ_MEDIA_IMAGES)
            }
            if (!hasPermission(Manifest.permission.READ_MEDIA_VIDEO)) {
                permissions.add(Manifest.permission.READ_MEDIA_VIDEO)
            }
            if (!hasPermission(Manifest.permission.READ_MEDIA_AUDIO)) {
                permissions.add(Manifest.permission.READ_MEDIA_AUDIO)
            }
        } else if (!hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE)) {
            permissions.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

        if (permissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                permissions.toTypedArray(),
                STORAGE_PERMISSION_REQUEST
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                })
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        }
    }

    private fun readMediaArtwork(path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.embeddedPicture
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun readVideoThumbnail(path: String): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val bitmap = retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: return null
            bitmapToJpeg(bitmap)
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun renderPdfFirstPage(path: String): ByteArray? {
        val file = File(path)
        if (!file.exists()) return null
        val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        return try {
            PdfRenderer(descriptor).use { renderer ->
                if (renderer.pageCount <= 0) return null
                renderer.openPage(0).use { page ->
                    val scale = 2.0f
                    val width = (page.width * scale).toInt().coerceAtLeast(1)
                    val height = (page.height * scale).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    bitmap.recycle()
                    stream.toByteArray()
                }
            }
        } catch (_: Exception) {
            null
        } finally {
            try {
                descriptor.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun speakText(text: String) {
        val current = textToSpeech
        if (current != null) {
            current.speak(text, TextToSpeech.QUEUE_FLUSH, null, "securevault-tts")
            return
        }
        textToSpeech = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                textToSpeech?.language = Locale.getDefault()
                textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "securevault-tts")
            }
        }
    }

    private fun bitmapToJpeg(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 82, stream)
        return stream.toByteArray()
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
