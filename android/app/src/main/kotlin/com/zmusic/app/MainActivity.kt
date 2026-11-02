package com.zmusic.app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val updateSourcePermissionRequestCode = 4102
        private const val updateInstallRequestCode = 4103
        private const val pendingUpdatePathKey = "zmusic.pending_update_path"
        private const val updateLogTag = "ZmusicUpdate"
    }

    private lateinit var mediaChannel: MethodChannel
    private var pendingUpdatePath: String? = null
    private val mediaCommandHandler: (String) -> Unit = { command ->
        runOnUiThread {
            if (::mediaChannel.isInitialized) {
                mediaChannel.invokeMethod("mediaButton", command)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingUpdatePath = savedInstanceState?.getString(pendingUpdatePathKey)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingUpdatePath?.let { outState.putString(pendingUpdatePathKey, it) }
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
        if (pendingUpdatePath != null) {
            result.error("install-busy", "已有更新正在等待安装授权。", null)
            return
        }
        Log.i(
            updateLogTag,
            "请求安装更新：device=${Build.MANUFACTURER}/${Build.MODEL}, " +
                "sdk=${Build.VERSION.SDK_INT}, target=${applicationInfo.targetSdkVersion}",
        )
        val isDiLink = applicationInfo.targetSdkVersion <= 29
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            if (isDiLink) {
                Log.w(updateLogTag, "车机未提供安装未知应用授权页面，直接尝试系统安装程序")
                launchSystemInstaller(path, result)
                return
            }
            // Keep the path across activity recreation without retaining a Flutter reply.
            pendingUpdatePath = path
            val permissionIntent =
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
            try {
                startActivityForResult(permissionIntent, updateSourcePermissionRequestCode)
            } catch (error: Exception) {
                pendingUpdatePath = null
                Log.w(updateLogTag, "无法打开安装未知应用授权页面", error)
                result.error(
                    "install-permission-unavailable",
                    error.message ?: "系统没有提供“安装未知应用”授权页面。",
                    null,
                )
                return
            }
            result.success("permission-requested")
            return
        }
        launchSystemInstaller(path, result)
    }

    @Suppress("DEPRECATION")
    private fun launchSystemInstaller(path: String, result: MethodChannel.Result?) {
        try {
            val updateFile = File(path)
            if (!updateFile.isFile) {
                Log.w(updateLogTag, "更新文件不存在：$path")
                reportInstallError(result, "missing-update", "更新文件不存在，请重新下载。")
                return
            }
            val updateUri =
                FileProvider.getUriForFile(
                    this,
                    "$packageName.update_files",
                    updateFile,
                )
            val isDiLink = applicationInfo.targetSdkVersion <= 29
            val actions = if (isDiLink) {
                listOf(Intent.ACTION_INSTALL_PACKAGE, Intent.ACTION_VIEW)
            } else {
                listOf(Intent.ACTION_VIEW, Intent.ACTION_INSTALL_PACKAGE)
            }
            for (action in actions) {
                val installIntent = Intent(action).apply {
                    setDataAndType(updateUri, "application/vnd.android.package-archive")
                    clipData = ClipData.newRawUri("Zmusic update", updateUri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    if (isDiLink) {
                        putExtra(Intent.EXTRA_RETURN_RESULT, true)
                    }
                }
                try {
                    Log.i(updateLogTag, "请求系统安装程序：action=$action")
                    if (isDiLink) {
                        // Preserve the calling package for the head unit's installer.
                        startActivityForResult(installIntent, updateInstallRequestCode)
                    } else {
                        startActivity(installIntent)
                    }
                    result?.success("installer-requested")
                    return
                } catch (error: ActivityNotFoundException) {
                    Log.w(updateLogTag, "系统不支持安装动作：$action", error)
                }
            }
            reportInstallError(result, "missing-installer", "系统没有可用的 APK 安装程序。")
        } catch (error: Exception) {
            Log.w(updateLogTag, "打开系统安装程序失败", error)
            reportInstallError(
                result,
                "install-update-failed",
                "无法打开系统安装程序：${error.message ?: error.javaClass.simpleName}",
            )
        }
    }

    private fun reportInstallError(result: MethodChannel.Result?, code: String, message: String) {
        if (result != null) {
            result.error(code, message, null)
        } else {
            // Permission and installer callbacks can arrive after the Flutter reply is closed.
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == updateInstallRequestCode) {
            Log.i(updateLogTag, "系统安装程序返回：result=$resultCode")
            if (resultCode != RESULT_OK) {
                val message = if (resultCode == RESULT_CANCELED) {
                    "安装尚未完成，更新包已保留，可重新点击更新。"
                } else {
                    "系统安装失败，更新包已保留。"
                }
                reportInstallError(null, "install-incomplete", message)
            }
            return
        }
        if (requestCode != updateSourcePermissionRequestCode) {
            return
        }
        val path = pendingUpdatePath ?: return
        pendingUpdatePath = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            Log.w(updateLogTag, "用户未授予安装未知应用权限，已取消本次安装")
            reportInstallError(
                null,
                "install-permission-denied",
                "未允许 Zmusic 安装未知应用，更新包已保留。",
            )
            return
        }
        launchSystemInstaller(path, null)
    }

    override fun onDestroy() {
        MediaControlBridge.detach(mediaCommandHandler)
        super.onDestroy()
    }
}
