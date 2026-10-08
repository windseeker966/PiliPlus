package com.example.piliplus

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * 把 Dart 端 UsageLog 的事件批量交给「本地时间采集」（com.wind.timetracker）的 ContentProvider。
 * 对方未安装或拒绝时返回错误，由 Dart 端保留事件稍后重试。
 */
object UsageLogBridge {
    private const val CHANNEL = "piliplus/usage_log"
    private val PROVIDER: Uri = Uri.parse("content://com.wind.timetracker.events")
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "send") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val events = call.arguments as? String
            if (events == null) {
                result.error("bad_args", "events must be a JSON string", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val extras = Bundle().apply { putString("events", events) }
                    val reply = appContext.contentResolver.call(PROVIDER, "record", null, extras)
                    val saved = reply?.getInt("saved") ?: 0
                    mainHandler.post { result.success(saved) }
                } catch (e: Exception) {
                    mainHandler.post { result.error("unavailable", e.message, null) }
                }
            }
        }
    }
}
