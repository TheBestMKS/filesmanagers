package com.filesmanagers.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.graphics.pdf.PdfRenderer
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "filesmanagers/platform"
        private const val STORAGE_PERMISSION_REQUEST = 7301
        private const val NOTIFICATION_PERMISSION_REQUEST = 7302
        private const val PICK_FILE_REQUEST = 7401
        private const val PICK_DIRECTORY_REQUEST = 7402
        private const val MEDIA_NOTIFICATION_ID = 7601
        private const val MEDIA_CHANNEL_ID = "filesmanagers_media"
        private const val MEDIA_ACTION = "com.filesmanagers.app.MEDIA_ACTION"
        private var mediaMethodChannel: MethodChannel? = null

        init {
            System.loadLibrary("crypt_core")
        }

        fun dispatchMediaCommand(context: Context, command: String) {
            val channel = mediaMethodChannel
            if (channel != null) {
                channel.invokeMethod("mediaControl", command)
                return
            }
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("mediaCommand", command)
            }
            context.startActivity(intent)
        }

        fun commandForMediaKey(keyCode: Int): String? =
            when (keyCode) {
                KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
                KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
                KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
                KeyEvent.KEYCODE_MEDIA_STOP -> "stop"
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> "playPause"
                else -> null
            }

        fun dispatchMediaButtonIntent(context: Context, intent: Intent?): Boolean {
            if (intent?.action != Intent.ACTION_MEDIA_BUTTON) return false
            @Suppress("DEPRECATION")
            val event = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
            if (event.action != KeyEvent.ACTION_DOWN) return true
            val command = commandForMediaKey(event.keyCode) ?: return false
            dispatchMediaCommand(context, command)
            return true
        }
    }

    private var textToSpeech: TextToSpeech? = null
    private var pendingPickFileResult: Result? = null
    private var pendingPickDirectoryResult: Result? = null
    private var mediaSession: MediaSession? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        mediaMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
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
                "pickFile" -> pickFile(result)
                "pickDirectory" -> pickDirectory(result)
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
                "stopSpeaking" -> {
                    textToSpeech?.stop()
                    result.success(null)
                }
                "updateMediaNotification" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: ""
                    val subtitle = args?.get("subtitle") as? String ?: ""
                    val playing = args?.get("playing") as? Boolean ?: false
                    val artworkPath = args?.get("artworkPath") as? String
                    showMediaNotification(title, subtitle, playing, artworkPath)
                    result.success(null)
                }
                "clearMediaNotification" -> {
                    clearMediaNotification()
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.arguments as? String
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "APK path is empty", null)
                        return@setMethodCallHandler
                    }
                    installApk(path)
                    result.success(null)
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
        if (dispatchMediaButtonIntent(this, intent)) return
        intent.getStringExtra("mediaCommand")?.let {
            mediaMethodChannel?.invokeMethod("mediaControl", it)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            commandForMediaKey(event.keyCode)?.let {
                dispatchMediaCommand(this, it)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    @Deprecated("Deprecated in Android API, still used for ACTION_OPEN_DOCUMENT compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_FILE_REQUEST -> {
                val pending = pendingPickFileResult ?: return
                pendingPickFileResult = null
                if (resultCode != Activity.RESULT_OK) {
                    pending.success(null)
                    return
                }
                val uri = data?.data
                if (uri == null) {
                    pending.success(null)
                    return
                }
                tryTakePersistablePermission(uri, data.flags)
                pending.success(copyContentUri(uri))
            }
            PICK_DIRECTORY_REQUEST -> {
                val pending = pendingPickDirectoryResult ?: return
                pendingPickDirectoryResult = null
                if (resultCode != Activity.RESULT_OK) {
                    pending.success(null)
                    return
                }
                val uri = data?.data
                if (uri == null) {
                    pending.success(null)
                    return
                }
                tryTakePersistablePermission(uri, data.flags)
                pending.success(resolveTreeUriToPath(uri) ?: uri.toString())
            }
        }
    }

    override fun onDestroy() {
        try {
            textToSpeech?.stop()
            textToSpeech?.shutdown()
        } catch (_: Exception) {
        }
        textToSpeech = null
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    private fun mediaPendingIntent(command: String): PendingIntent {
        val intent = Intent(this, MediaActionReceiver::class.java).apply {
            action = MEDIA_ACTION
            putExtra("command", command)
        }
        return PendingIntent.getBroadcast(
            this,
            command.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun ensureMediaSession(): MediaSession {
        mediaSession?.let { return it }
        val session = MediaSession(this, "FilesManagersMediaSession")
        @Suppress("DEPRECATION")
        session.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                dispatchMediaCommand(this@MainActivity, "play")
            }

            override fun onPause() {
                dispatchMediaCommand(this@MainActivity, "pause")
            }

            override fun onSkipToNext() {
                dispatchMediaCommand(this@MainActivity, "next")
            }

            override fun onSkipToPrevious() {
                dispatchMediaCommand(this@MainActivity, "previous")
            }

            override fun onStop() {
                dispatchMediaCommand(this@MainActivity, "stop")
            }

            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                return dispatchMediaButtonIntent(this@MainActivity, mediaButtonIntent) ||
                    super.onMediaButtonEvent(mediaButtonIntent)
            }
        })
        mediaSession = session
        return session
    }

    private fun updateMediaSessionState(
        session: MediaSession,
        title: String,
        subtitle: String,
        playing: Boolean,
        artwork: Bitmap?
    ) {
        val playbackState = if (playing) {
            PlaybackState.STATE_PLAYING
        } else {
            PlaybackState.STATE_PAUSED
        }
        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SEEK_TO
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    playbackState,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (playing) 1.0f else 0.0f
                )
                .build()
        )
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, subtitle)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, subtitle)
        if (artwork != null) {
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, artwork)
            metadata.putBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON, artwork)
        }
        session.setMetadata(metadata.build())
        session.isActive = true
    }

    private fun mediaAction(icon: Int, title: String, command: String): Notification.Action =
        Notification.Action.Builder(icon, title, mediaPendingIntent(command)).build()

    private fun mediaNotificationBuilder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MEDIA_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

    private fun loadNotificationArtwork(path: String?): Bitmap? {
        if (path.isNullOrBlank() ||
            path.startsWith("remote://") ||
            path.startsWith("torrent://") ||
            path.startsWith("zip://") ||
            path.startsWith("rar://") ||
            path.startsWith("http://") ||
            path.startsWith("https://")
        ) {
            return null
        }
        val file = File(path)
        if (!file.exists()) return null
        val bytes = readMediaArtwork(path) ?: readVideoThumbnail(path) ?: return null
        return try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (_: Exception) {
            null
        }
    }

    private fun clearMediaNotification() {
        getSystemService(NotificationManager::class.java).cancel(MEDIA_NOTIFICATION_ID)
        mediaSession?.let {
            it.setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_STOPPED, 0L, 0.0f)
                    .build()
            )
            it.isActive = false
        }
    }

    private fun showMediaNotification(
        title: String,
        subtitle: String,
        playing: Boolean,
        artworkPath: String?
    ) {
        if (title.isBlank()) {
            clearMediaNotification()
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                MEDIA_CHANNEL_ID,
                "Files Managers media",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background media controls"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        val session = ensureMediaSession()
        val artwork = loadNotificationArtwork(artworkPath)
        updateMediaSessionState(session, title, subtitle, playing, artwork)
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIcon = if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val builder = mediaNotificationBuilder()
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(openIntent)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(playing)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_LOW)
            .setLargeIcon(artwork)
            .addAction(mediaAction(android.R.drawable.ic_media_previous, "Previous", "previous"))
            .addAction(mediaAction(playPauseIcon, if (playing) "Pause" else "Play", "playPause"))
            .addAction(mediaAction(android.R.drawable.ic_media_next, "Next", "next"))
            .addAction(mediaAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", "stop"))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setColorized(artwork != null)
            builder.setColor(0xFF2563EB.toInt())
        }
        getSystemService(NotificationManager::class.java)
            .notify(MEDIA_NOTIFICATION_ID, builder.build())
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
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

    private fun pickFile(result: Result) {
        if (pendingPickFileResult != null || pendingPickDirectoryResult != null) {
            result.error("picker_busy", "Another Android picker is already open.", null)
            return
        }
        pendingPickFileResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
            startActivityForResult(intent, PICK_FILE_REQUEST)
        } catch (error: Exception) {
            pendingPickFileResult = null
            result.error("pick_file_failed", error.message, null)
        }
    }

    private fun pickDirectory(result: Result) {
        if (pendingPickFileResult != null || pendingPickDirectoryResult != null) {
            result.error("picker_busy", "Another Android picker is already open.", null)
            return
        }
        pendingPickDirectoryResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
        } catch (error: Exception) {
            pendingPickDirectoryResult = null
            result.error("pick_directory_failed", error.message, null)
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
            current.speak(text, TextToSpeech.QUEUE_FLUSH, null, "filesmanagers-tts")
            return
        }
        textToSpeech = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                textToSpeech?.language = Locale.getDefault()
                textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "filesmanagers-tts")
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

    private fun tryTakePersistablePermission(uri: Uri, flags: Int) {
        try {
            val takeFlags = flags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: Exception) {
        }
    }

    private fun resolveTreeUriToPath(uri: Uri): String? {
        return try {
            val documentId = DocumentsContract.getTreeDocumentId(uri)
            val separator = documentId.indexOf(':')
            val volume = if (separator >= 0) documentId.substring(0, separator) else documentId
            val relative = if (separator >= 0) documentId.substring(separator + 1) else ""
            if (volume.equals("primary", ignoreCase = true)) {
                val base = Environment.getExternalStorageDirectory().absolutePath
                if (relative.isEmpty()) base else "$base/$relative"
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
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

class MediaActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (MainActivity.dispatchMediaButtonIntent(context, intent)) return
        if (intent.action != "com.filesmanagers.app.MEDIA_ACTION") return
        val command = intent.getStringExtra("command") ?: return
        MainActivity.dispatchMediaCommand(context, command)
    }
}
