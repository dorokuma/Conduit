package com.gwitko.conduit

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterFragmentActivity() {
    private lateinit var fidoUsbCtapTransport: FidoUsbCtapTransport

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupJavaCrashHandler()
    }

    private fun setupJavaCrashHandler() {
        val originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        if (originalHandler is ConduitCrashHandler) {
            return
        }
        Thread.setDefaultUncaughtExceptionHandler(ConduitCrashHandler(originalHandler))
    }

    private inner class ConduitCrashHandler(
        private val originalHandler: Thread.UncaughtExceptionHandler?
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, throwable: Throwable) {
            try {
                val logsDir = File(filesDir, "logs")
                val crashDir = File(logsDir, "crash")
                if (!crashDir.exists()) {
                    crashDir.mkdirs()
                }
                val timestamp = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss_SSS", Locale.US).format(Date())
                val crashFile = File(crashDir, "crash_java_${timestamp}.log")
                val sw = StringWriter()
                val pw = PrintWriter(sw)
                throwable.printStackTrace(pw)
                val stackTrace = sw.toString()

                val content = buildString {
                    appendLine("================ FATAL JAVA/ANDROID EXCEPTION ================")
                    appendLine("Time: ${Date()}")
                    appendLine("Thread: ${thread.name} (id: ${thread.id})")
                    appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL} (API: ${Build.VERSION.SDK_INT}, OS: ${Build.VERSION.RELEASE})")
                    appendLine("ABIs: ${Build.SUPPORTED_ABIS.joinToString(", ")}")
                    appendLine("Exception: ${throwable.javaClass.name}: ${throwable.message}")
                    appendLine("Stack Trace:")
                    appendLine(stackTrace)
                    appendLine("==============================================================")
                }
                crashFile.writeText(content)

                // Append to active app.log
                val appLog = File(logsDir, "app.log")
                val logTime = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
                val logEntry = "$logTime [FATAL] [JavaCrash] Thread [${thread.name}]: ${throwable.message}\n$stackTrace\n"
                appLog.appendText(logEntry)
            } catch (e: Throwable) {
                e.printStackTrace()
            } finally {
                originalHandler?.uncaughtException(thread, throwable)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fidoUsbCtapTransport = FidoUsbCtapTransport(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_KEEPALIVE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val sessionCount = call.argument<Int>("sessionCount") ?: 0
                    BackgroundConnectionService.start(this, sessionCount)
                    result.success(null)
                }
                "stop" -> {
                    BackgroundConnectionService.stop(this)
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FIDO_USB_CHANNEL,
        ).setMethodCallHandler { call, result ->
            fidoUsbCtapTransport.handle(call, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCAL_SHELL_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "environment" -> result.success(
                    mapOf(
                        "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
                        "filesDir" to filesDir.absolutePath,
                        "sharedStorageFeatureEnabled" to BuildConfig.FULL_STORAGE_ACCESS,
                        "sharedStorageDir" to sharedStorageDir(),
                        "sharedStorageAccessGranted" to hasSharedStorageAccess(),
                        "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                    ),
                )
                "requestSharedStorageAccess" -> {
                    requestSharedStorageAccess()
                    result.success(hasSharedStorageAccess())
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXIT_INFO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLastExitInfo" -> {
                    result.success(getLastExitInfo())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getLastExitInfo(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return null
        }
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return null
            // N=1: query the single most recent exit reason for this package.
            // fast cross-process binder call (~1ms).
            val exitInfos = am.getHistoricalProcessExitReasons(packageName, 0, 1)
            if (exitInfos.isNullOrEmpty()) {
                return null
            }
            val lastExit = exitInfos[0]
            val reasonName = when (lastExit.reason) {
                ApplicationExitInfo.REASON_EXIT_SELF -> "REASON_EXIT_SELF"
                ApplicationExitInfo.REASON_SIGNALED -> "REASON_SIGNALED"
                ApplicationExitInfo.REASON_LOW_MEMORY -> "REASON_LOW_MEMORY"
                ApplicationExitInfo.REASON_CRASH -> "REASON_CRASH"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "REASON_CRASH_NATIVE"
                ApplicationExitInfo.REASON_ANR -> "REASON_ANR"
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "REASON_INITIALIZATION_FAILURE"
                ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "REASON_PERMISSION_CHANGE"
                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "REASON_EXCESSIVE_RESOURCE_USAGE"
                ApplicationExitInfo.REASON_USER_REQUESTED -> "REASON_USER_REQUESTED"
                ApplicationExitInfo.REASON_USER_STOPPED -> "REASON_USER_STOPPED"
                ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "REASON_DEPENDENCY_DIED"
                ApplicationExitInfo.REASON_OTHER -> "REASON_OTHER"
                14 -> "REASON_FREEZER"
                15 -> "REASON_PACKAGE_STATE_CHANGE"
                16 -> "REASON_PACKAGE_UPDATED"
                17 -> "REASON_MEMORY_LIMITER"
                18 -> "REASON_ANOMALY"
                else -> "REASON_UNKNOWN"
            }

            var tombstoneName: String? = null
            val shouldReadTrace = lastExit.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                lastExit.reason == ApplicationExitInfo.REASON_CRASH ||
                lastExit.reason == ApplicationExitInfo.REASON_ANR ||
                lastExit.reason == ApplicationExitInfo.REASON_SIGNALED

            if (shouldReadTrace) {
                try {
                    val traceStream = lastExit.traceInputStream
                    if (traceStream != null) {
                        val logsDir = File(filesDir, "logs")
                        val crashDir = File(logsDir, "crash")
                        if (!crashDir.exists()) {
                            crashDir.mkdirs()
                        }
                        val fileName = "tombstone_${lastExit.timestamp}.bin"
                        val tombstoneFile = File(crashDir, fileName)
                        traceStream.use { input ->
                            tombstoneFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        tombstoneName = fileName
                    }
                } catch (e: Throwable) {
                    // Graceful degradation when trace cannot be read or written
                }
            }

            mapOf(
                "reason" to lastExit.reason,
                "reasonName" to reasonName,
                "description" to lastExit.description,
                "timestamp" to lastExit.timestamp,
                "pid" to lastExit.pid,
                "status" to lastExit.status,
                "importance" to lastExit.importance,
                "pss" to lastExit.pss,
                "rss" to lastExit.rss,
                "tombstone" to tombstoneName,
            )
        } catch (e: Throwable) {
            null
        }
    }

    private fun hasSharedStorageAccess(): Boolean {
        if (!BuildConfig.FULL_STORAGE_ACCESS) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestSharedStorageAccess() {
        if (!BuildConfig.FULL_STORAGE_ACCESS) return
        if (hasSharedStorageAccess()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                SHARED_STORAGE_PERMISSION_REQUEST_CODE,
            )
        }
    }

    private fun sharedStorageDir(): String {
        if (!BuildConfig.FULL_STORAGE_ACCESS) return ""
        return Environment.getExternalStorageDirectory().absolutePath
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    companion object {
        const val BACKGROUND_KEEPALIVE_CHANNEL = "conduit/background_keepalive"
        const val EXIT_INFO_CHANNEL = "conduit/exit_info"
        const val FIDO_USB_CHANNEL = "conduit/fido_usb"
        const val LOCAL_SHELL_CHANNEL = "conduit/local_shell"
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 2001
        private const val SHARED_STORAGE_PERMISSION_REQUEST_CODE = 2002
    }
}

class BackgroundConnectionService : Service() {
    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val sessionCount = intent?.getIntExtra(SESSION_COUNT_EXTRA, 0) ?: 0
        val notification = buildNotification(sessionCount)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Active sessions",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps active sessions running while Conduit is in the background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(sessionCount: Int): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val sessionLabel = if (sessionCount == 1) "session" else "sessions"

        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Conduit")
            .setContentText("$sessionCount active $sessionLabel")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "ssh_sessions"
        private const val NOTIFICATION_ID = 1001
        private const val SESSION_COUNT_EXTRA = "session_count"

        fun start(context: Context, sessionCount: Int) {
            val intent = Intent(context, BackgroundConnectionService::class.java).apply {
                putExtra(SESSION_COUNT_EXTRA, sessionCount)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BackgroundConnectionService::class.java))
        }
    }
}
