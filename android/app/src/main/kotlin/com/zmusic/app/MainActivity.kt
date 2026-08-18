package com.zmusic.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val updateSourcePermissionRequestCode = 4102
    }

    private lateinit var mediaChannel: MethodChannel
    private var pendingUpdatePath: String? = null
    private var pendingInstallResult: MethodChannel.Result? = null
    private val mediaCommandHandler: (String) -> Unit = { command ->
        runOnUiThread {
            if (::mediaChannel.isInitialized) {
                mediaChannel.invokeMethod("mediaButton", command)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zmusic.app/task")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                    "getUpdateChannel" -> {
                        val channel = if (applicationInfo.targetSdkVersion <= 29) {
                            "android-dilink"
                        } else {
                            "android"
                        }
                        result.success(channel)
                    }
                    "installUpdate" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("invalid-update", "更新文件路径无效。", null)
                        } else {
                            requestUpdateInstall(path, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        mediaChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.zmusic.app/media_session",
            )
        MediaControlBridge.attach(mediaCommandHandler)
        mediaChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> result.success(true)
                "updateState" -> {
                    val values = call.arguments as? Map<*, *>
                    if (values == null) {
                        result.error("invalid-arguments", "Expected a state map.", null)
                    } else {
                        ZmusicMediaSessionService.update(this, values)
                        result.success(null)
                    }
                }
                "clear" -> {
                    ZmusicMediaSessionService.clear(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (MediaControlBridge.dispatch(event)) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    private fun requestUpdateInstall(path: String, result: MethodChannel.Result) {
        if (pendingInstallResult != null) {
            result.error("install-busy", "已有更新正在等待安装授权。", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            pendingUpdatePath = path
            pendingInstallResult = result
            val permissionIntent =
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
            startActivityForResult(permissionIntent, updateSourcePermissionRequestCode)
            return
        }
        launchSystemInstaller(path, result)
    }

    private fun launchSystemInstaller(path: String, result: MethodChannel.Result) {
        try {
            val updateFile = File(path)
            if (!updateFile.isFile) {
                result.error("missing-update", "更新文件不存在。", null)
                return
            }
            val updateUri =
                FileProvider.getUriForFile(
                    this,
                    "$packageName.update_files",
                    updateFile,
                )
            val installIntent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(updateUri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            if (installIntent.resolveActivity(packageManager) == null) {
                result.error("missing-installer", "系统没有可用的 APK 安装程序。", null)
                return
            }
            startActivity(installIntent)
            result.success(null)
        } catch (error: Exception) {
            result.error("install-update-failed", error.message ?: "无法打开系统安装程序。", null)
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != updateSourcePermissionRequestCode) {
            return
        }
        val path = pendingUpdatePath
        val result = pendingInstallResult
        pendingUpdatePath = null
        pendingInstallResult = null
        if (path == null || result == null) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            result.error("install-permission-denied", "未允许 Zmusic 安装未知来源应用。", null)
            return
        }
        launchSystemInstaller(path, result)
    }

    override fun onDestroy() {
        MediaControlBridge.detach(mediaCommandHandler)
        super.onDestroy()
    }
}
