package pl.truckmaps.truckmaps_app

import android.content.Intent
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/// Głos nawigacji: syntezator mowy Androida (kanał `truckmaps/speech`, zob. speech.dart).
/// Linki `truckmaps://` (powrót z logowania): kanał `truckmaps/links` (zob. app_auth.dart).
class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var links: MethodChannel? = null
    private var initialLink: String? = null
    private var ready = false
    private var pending: Pair<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = appLink(intent)
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "truckmaps/links").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    // Link startowy oddajemy raz – ponowne restore() nie wymienia kodu drugi raz.
                    result.success(initialLink)
                    initialLink = null
                } else {
                    result.notImplemented()
                }
            }
        }
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

    // Aplikacja już działa (launchMode singleTop) – link przychodzi tutaj.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        appLink(intent)?.let { links?.invokeMethod("link", it) }
    }

    private fun appLink(intent: Intent?): String? =
        intent?.data?.takeIf { intent.action == Intent.ACTION_VIEW && it.scheme == "truckmaps" }?.toString()

    override fun onDestroy() {
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }
}
