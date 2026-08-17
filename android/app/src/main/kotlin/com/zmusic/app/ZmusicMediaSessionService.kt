package com.zmusic.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent

internal object MediaControlBridge {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var listener: ((String) -> Unit)? = null

    fun attach(value: (String) -> Unit) {
        listener = value
    }

    fun detach(value: (String) -> Unit) {
        if (listener === value) {
            listener = null
        }
    }

    fun dispatch(command: String) {
        mainHandler.post { listener?.invoke(command) }
    }

    fun dispatch(event: KeyEvent): Boolean {
        val command =
            when (event.keyCode) {
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_HEADSETHOOK -> "playPause"
                KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
                KeyEvent.KEYCODE_MEDIA_PAUSE,
                KeyEvent.KEYCODE_MEDIA_STOP -> "pause"
                KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
                else -> return false
            }
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            dispatch(command)
        }
        return true
    }
}

class ZmusicMediaSessionService : Service() {
    private lateinit var mediaSession: MediaSession
    private var state = MediaState()

    override fun onCreate() {
        super.onCreate()
        current = this
        createNotificationChannel()
        mediaSession = MediaSession(this, "Zmusic").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() = MediaControlBridge.dispatch("play")

                    override fun onPause() = MediaControlBridge.dispatch("pause")

                    override fun onSkipToNext() = MediaControlBridge.dispatch("next")

                    override fun onSkipToPrevious() = MediaControlBridge.dispatch("previous")

                    @Suppress("DEPRECATION")
                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val event =
                            mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                                ?: return super.onMediaButtonEvent(mediaButtonIntent)
                        if (MediaControlBridge.dispatch(event)) {
                            return true
                        }
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }
                },
                Handler(Looper.getMainLooper()),
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionPlay -> MediaControlBridge.dispatch("play")
            actionPause -> MediaControlBridge.dispatch("pause")
            actionNext -> MediaControlBridge.dispatch("next")
            actionPrevious -> MediaControlBridge.dispatch("previous")
            actionUpdate -> applyState(MediaState.fromIntent(intent))
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (current === this) {
            current = null
        }
        mediaSession.isActive = false
        mediaSession.release()
        super.onDestroy()
    }

    private fun applyState(value: MediaState) {
        state = value
        if (!value.hasTrack) {
            stopSession()
            return
        }

        var actions =
            PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE
        if (value.canSkipPrevious) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        }
        if (value.canSkipNext) {
            actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        }
        val playbackState = if (value.isPlaying) {
            PlaybackState.STATE_PLAYING
        } else {
            PlaybackState.STATE_PAUSED
        }
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    playbackState,
                    value.positionMs.coerceAtLeast(0),
                    if (value.isPlaying) 1f else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .build(),
        )
        val metadata =
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, value.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, value.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, value.album)
        if (value.durationMs > 0) {
            metadata.putLong(MediaMetadata.METADATA_KEY_DURATION, value.durationMs)
        }
        if (value.artworkUrl.isNotBlank()) {
            metadata.putString(MediaMetadata.METADATA_KEY_ART_URI, value.artworkUrl)
        }
        mediaSession.setMetadata(metadata.build())
        mediaSession.isActive = true
        startForeground(notificationId, buildNotification(value))
    }

    private fun stopSession() {
        mediaSession.isActive = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(value: MediaState): Notification {
        val contentIntent =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, notificationChannelId)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(value.title.ifBlank { "Zmusic" })
            .setContentText(value.artist)
            .setSubText(value.album)
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(value.isPlaying)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(notificationAction(actionPrevious, android.R.drawable.ic_media_previous))
            .addAction(
                notificationAction(
                    if (value.isPlaying) actionPause else actionPlay,
                    if (value.isPlaying) {
                        android.R.drawable.ic_media_pause
                    } else {
                        android.R.drawable.ic_media_play
                    },
                ),
            )
            .addAction(notificationAction(actionNext, android.R.drawable.ic_media_next))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
            .build()
    }

    private fun notificationAction(action: String, icon: Int): Notification.Action {
        val requestCode = when (action) {
            actionPrevious -> 1
            actionPlay -> 2
            actionPause -> 3
            else -> 4
        }
        val intent = Intent(this, ZmusicMediaSessionService::class.java).setAction(action)
        val pendingIntent =
            PendingIntent.getService(
                this,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Action.Builder(icon, "", pendingIntent).build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                notificationChannelId,
                "音乐播放",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "显示当前歌曲和播放控制"
                setSound(null, null)
            },
        )
    }

    companion object {
        private const val notificationChannelId = "zmusic_playback"
        private const val notificationId = 1001
        private const val actionUpdate = "com.zmusic.app.media.UPDATE"
        private const val actionPlay = "com.zmusic.app.media.PLAY"
        private const val actionPause = "com.zmusic.app.media.PAUSE"
        private const val actionNext = "com.zmusic.app.media.NEXT"
        private const val actionPrevious = "com.zmusic.app.media.PREVIOUS"

        @Volatile
        private var current: ZmusicMediaSessionService? = null

        fun update(context: Context, values: Map<*, *>) {
            val state = MediaState.fromMap(values)
            if (!state.hasTrack) {
                clear(context)
                return
            }
            current?.let {
                it.applyState(state)
                return
            }
            val intent = Intent(context, ZmusicMediaSessionService::class.java).apply {
                action = actionUpdate
                state.writeTo(this)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun clear(context: Context) {
            current?.stopSession() ?: context.stopService(
                Intent(context, ZmusicMediaSessionService::class.java),
            )
        }
    }

    private data class MediaState(
        val hasTrack: Boolean = false,
        val isPlaying: Boolean = false,
        val canSkipPrevious: Boolean = false,
        val canSkipNext: Boolean = false,
        val title: String = "",
        val artist: String = "",
        val album: String = "",
        val artworkUrl: String = "",
        val positionMs: Long = 0,
        val durationMs: Long = 0,
    ) {
        fun writeTo(intent: Intent) {
            intent.putExtra("hasTrack", hasTrack)
            intent.putExtra("isPlaying", isPlaying)
            intent.putExtra("canSkipPrevious", canSkipPrevious)
            intent.putExtra("canSkipNext", canSkipNext)
            intent.putExtra("title", title)
            intent.putExtra("artist", artist)
            intent.putExtra("album", album)
            intent.putExtra("artworkUrl", artworkUrl)
            intent.putExtra("positionMs", positionMs)
            intent.putExtra("durationMs", durationMs)
        }

        companion object {
            fun fromMap(values: Map<*, *>): MediaState =
                MediaState(
                    hasTrack = values["hasTrack"] as? Boolean ?: false,
                    isPlaying = values["isPlaying"] as? Boolean ?: false,
                    canSkipPrevious = values["canSkipPrevious"] as? Boolean ?: false,
                    canSkipNext = values["canSkipNext"] as? Boolean ?: false,
                    title = values["title"] as? String ?: "",
                    artist = values["artist"] as? String ?: "",
                    album = values["album"] as? String ?: "",
                    artworkUrl = values["artworkUrl"] as? String ?: "",
                    positionMs = (values["positionMs"] as? Number)?.toLong() ?: 0,
                    durationMs = (values["durationMs"] as? Number)?.toLong() ?: 0,
                )

            fun fromIntent(intent: Intent): MediaState =
                MediaState(
                    hasTrack = intent.getBooleanExtra("hasTrack", false),
                    isPlaying = intent.getBooleanExtra("isPlaying", false),
                    canSkipPrevious = intent.getBooleanExtra("canSkipPrevious", false),
                    canSkipNext = intent.getBooleanExtra("canSkipNext", false),
                    title = intent.getStringExtra("title") ?: "",
                    artist = intent.getStringExtra("artist") ?: "",
                    album = intent.getStringExtra("album") ?: "",
                    artworkUrl = intent.getStringExtra("artworkUrl") ?: "",
                    positionMs = intent.getLongExtra("positionMs", 0),
                    durationMs = intent.getLongExtra("durationMs", 0),
                )
        }
    }
}
