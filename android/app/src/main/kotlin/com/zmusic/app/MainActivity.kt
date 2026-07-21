package com.zmusic.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var mediaChannel: MethodChannel
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

    override fun onDestroy() {
        MediaControlBridge.detach(mediaCommandHandler)
        super.onDestroy()
    }
}
