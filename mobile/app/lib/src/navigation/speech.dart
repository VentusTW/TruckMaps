import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Głos nawigacji: syntezator mowy systemu, bez dodatkowych pakietów i bez sieci.
abstract class Speaker {
  /// Mówi tekst; nowy komunikat przerywa poprzedni (ważniejszy jest bieżący).
  Future<void> speak(String text);

  Future<void> stop();

  Future<void> dispose();
}

/// Syntezator systemu w danym języku (np. "pl-PL"): Android i iOS – kanał do kodu
/// natywnego (TextToSpeech / AVSpeechSynthesizer), Windows – głosy systemu (SAPI).
Speaker systemSpeaker(String language) {
  if (kIsWeb) return SilentSpeaker();
  if (Platform.isWindows) return WindowsSpeaker(language);
  if (Platform.isAndroid || Platform.isIOS) return ChannelSpeaker(language);
  return SilentSpeaker();
}

class SilentSpeaker implements Speaker {
  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Android / iOS: `MainActivity` (Kotlin) obsługuje kanał `truckmaps/speech`.
class ChannelSpeaker implements Speaker {
  ChannelSpeaker(this.language);

  static const _channel = MethodChannel('truckmaps/speech');
  final String language;

  @override
  Future<void> speak(String text) => _call('speak', {'text': text, 'language': language});

  @override
  Future<void> stop() => _call('stop');

  @override
  Future<void> dispose() => stop();

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Brak kodu natywnego na tej platformie – nawigacja działa bez głosu.
    } on PlatformException {
      // Brak głosu w tym języku albo syntezatora – jak wyżej.
    }
  }
}

/// Windows: jeden proces PowerShell z System.Speech czyta komunikaty z wejścia
/// (bez opóźnienia na start przy każdym komunikacie).
class WindowsSpeaker implements Speaker {
  WindowsSpeaker(this.language);

  final String language;
  Future<Process>? _process;

  Future<Process> _start() => Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Console]::InputEncoding = [Text.Encoding]::UTF8; '
            'Add-Type -AssemblyName System.Speech; '
            r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
            r"try { $s.SelectVoiceByHints('NotSet', 'NotSet', 0, [Globalization.CultureInfo]'"
            "$language"
            "') } catch {}; "
            r'while (($line = [Console]::In.ReadLine()) -ne $null) { '
            r"$s.SpeakAsyncCancelAll(); if ($line -ne '') { [void]$s.SpeakAsync($line) } }",
      ]);

  Future<void> _send(String line) async {
    try {
      final process = await (_process ??= _start());
      process.stdin.add(utf8.encode('${line.replaceAll('\n', ' ')}\n'));
      await process.stdin.flush();
    } on Exception {
      // Bez PowerShella – bez głosu.
    }
  }

  @override
  Future<void> speak(String text) => _send(text);

  @override
  Future<void> stop() => _send('');

  @override
  Future<void> dispose() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    try {
      await (await process).stdin.close();
    } on Exception {
      // proces już zakończony
    }
  }
}
