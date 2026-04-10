package com.example.pmpml_journey_guide2

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.content.Intent
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val AUDIO_CHANNEL   = "com.pmpml.busbot/audio"
    private val STT_CHANNEL     = "com.pmpml.busbot/stt"
    private val STT_EVENT       = "com.pmpml.busbot/stt_events"
    private val VIBRATE_CHANNEL = "com.pmpml.busbot/vibrate"
    private val SMS_CHANNEL     = "com.pmpml.busbot/sms"

    private val SMS_PERMISSION_CODE = 101

    // Store pending SMS while waiting for runtime permission grant
    private var pendingSmsNumber: String? = null
    private var pendingSmsMessage: String? = null
    private var pendingSmsResult: MethodChannel.Result? = null

    private var recognizer: SpeechRecognizer? = null
    private var sttSink: EventChannel.EventSink? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var shouldLoop = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── 1. Audio mute / unmute ────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                when (call.method) {
                    "muteBeep" -> {
                        am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
                        result.success(null)
                    }
                    "unmuteBeep" -> {
                        am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── 2. SMS ────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSMS" -> {
                        val number  = call.argument<String>("number")  ?: ""
                        val message = call.argument<String>("message") ?: ""

                        // FIX 1: Always check & request runtime permission first
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
                            != PackageManager.PERMISSION_GRANTED) {
                            // Save pending call — will be retried in onRequestPermissionsResult
                            pendingSmsNumber  = number
                            pendingSmsMessage = message
                            pendingSmsResult  = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.SEND_SMS),
                                SMS_PERMISSION_CODE
                            )
                        } else {
                            doSendSms(number, message, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── 3. Vibration ──────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VIBRATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val vibrator = getVibrator()
                if (vibrator == null || !vibrator.hasVibrator()) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "gentle"  -> { vibrate(vibrator, longArrayOf(0, 200, 200, 200)); result.success(null) }
                    "strong"  -> { vibrate(vibrator, longArrayOf(0, 400, 150, 400, 150, 400)); result.success(null) }
                    "arrival" -> {
                        vibrate(vibrator, longArrayOf(
                            0, 200, 100, 200, 100, 200, 100, 200, 100, 200, 100, 200,
                            400, 500, 150, 500, 150, 500))
                        result.success(null)
                    }
                    "stop"    -> { vibrator.cancel(); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        // ── 4. Continuous STT ─────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startListening" -> {
                        shouldLoop = true
                        acquireWakeLock()
                        startNativeSTT()
                        result.success(null)
                    }
                    "stopListening" -> {
                        shouldLoop = false
                        stopNativeSTT()
                        releaseWakeLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── 5. STT event stream ───────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STT_EVENT)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) { sttSink = sink }
                override fun onCancel(args: Any?) { sttSink = null }
            })
    }

    // ── SMS helper ────────────────────────────────────────────
    private fun doSendSms(number: String, message: String, result: MethodChannel.Result) {
        try {
            // FIX 2: On API 31+ use createForDefaultSmsApp() not getDefault()
            // FIX 3: Split long messages so they don't silently fail
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                this.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }

            if (smsManager == null) {
                result.error("SMS_FAILED", "SmsManager unavailable", null)
                return
            }

            // Split message if > 160 chars
            val parts = smsManager.divideMessage(message)
            if (parts.size == 1) {
                smsManager.sendTextMessage(number, null, message, null, null)
            } else {
                smsManager.sendMultipartTextMessage(number, null, parts, null, null)
            }

            android.util.Log.d("BusBot_SMS", "✅ SMS sent to $number: $message")
            result.success("SMS_SENT")
        } catch (e: Exception) {
            android.util.Log.e("BusBot_SMS", "❌ SMS failed: ${e.message}")
            result.error("SMS_FAILED", e.message, null)
        }
    }

    // FIX 4: Handle runtime permission result and retry the pending SMS
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == SMS_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                android.util.Log.d("BusBot_SMS", "✅ SMS permission granted — retrying send")
                val n = pendingSmsNumber
                val m = pendingSmsMessage
                val r = pendingSmsResult
                if (n != null && m != null && r != null) {
                    doSendSms(n, m, r)
                }
            } else {
                android.util.Log.e("BusBot_SMS", "❌ SMS permission denied by user")
                pendingSmsResult?.error("PERMISSION_DENIED", "SMS permission denied", null)
            }
            pendingSmsNumber  = null
            pendingSmsMessage = null
            pendingSmsResult  = null
        }
    }

    // ── Vibrator helper ───────────────────────────────────────
    private fun getVibrator(): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            vm?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private fun vibrate(vibrator: Vibrator, pattern: LongArray) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val amplitudes = IntArray(pattern.size) { i -> if (i % 2 == 0) 0 else 255 }
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, amplitudes, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
        }
    }

    // ── Native STT ────────────────────────────────────────────
    private fun startNativeSTT() {
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(this)

        recognizer!!.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(p: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(v: Float) {}
            override fun onBufferReceived(b: ByteArray?) {}
            override fun onPartialResults(b: Bundle?) {
                val partial = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull() ?: return
                sttSink?.success("PARTIAL:$partial")
            }
            override fun onEvent(type: Int, p: Bundle?) {}

            override fun onResults(b: Bundle?) {
                val text = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull() ?: ""
                if (text.isNotBlank()) sttSink?.success("FINAL:$text")
                if (shouldLoop) startNativeSTT()
            }

            override fun onError(error: Int) {
                if (shouldLoop) {
                    android.os.Handler(mainLooper).postDelayed({
                        if (shouldLoop) startNativeSTT()
                    }, 500)
                }
            }

            override fun onEndOfSpeech() {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-IN")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 200L)
            putExtra("android.speech.extra.DICTATION_MODE", true)
        }

        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
        recognizer!!.startListening(intent)
        android.os.Handler(mainLooper).postDelayed({
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        }, 400)
    }

    private fun stopNativeSTT() {
        recognizer?.stopListening()
        recognizer?.destroy()
        recognizer = null
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "BusBot::WakeWordLock")
        wakeLock?.acquire(6 * 60 * 60 * 1000L)
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
    }

    override fun onDestroy() {
        shouldLoop = false
        stopNativeSTT()
        releaseWakeLock()
        super.onDestroy()
    }
}