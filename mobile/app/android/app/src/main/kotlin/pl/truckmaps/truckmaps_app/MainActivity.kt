package pl.truckmaps.truckmaps_app

import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/// Głos nawigacji: syntezator mowy Androida (kanał `truckmaps/speech`, zob. speech.dart).
class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pending: Pair<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "truckmaps/speech").setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    speak(call.argument<String>("text") ?: "", call.argument<String>("language") ?: "pl-PL")
                    result.success(null)
                }
                "stop" -> {
                    tts?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun speak(text: String, language: String) {
        val engine = tts
        if (engine == null || !ready) {
            // Syntezator startuje asynchronicznie – pierwszy komunikat czeka na gotowość.
            pending = text to language
            if (engine == null) {
                tts = TextToSpeech(this) { status ->
                    ready = status == TextToSpeech.SUCCESS
                    pending?.let { (t, l) -> if (ready) speak(t, l) }
                    pending = null
                }
            }
            return
        }
        engine.language = Locale.forLanguageTag(language)
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "truckmaps")
    }

    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }
}
