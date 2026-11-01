import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n.dart';

/// Zdjęcie z aparatu albo z pliku (`null` – anulowano).
typedef PhotoPicker = Future<Uint8List?> Function(bool camera);

Future<Uint8List?> pickPhoto(bool camera) async {
  final file = await ImagePicker().pickImage(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 3000,
    maxHeight: 3000,
  );
  return file?.readAsBytes();
}

/// Odczyt kodu Aztec na żywo z aparatu (`null` – anulowano).
typedef CodeScanner = Future<String?> Function(BuildContext context);

Future<String?> scanCode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const AztecScanScreen()));

/// Tekst ze zdjęcia dowodu z innego kraju UE, rozpoznany na telefonie (`null` – anulowano).
typedef TextReader = Future<String?> Function();

Future<String?> readCertificateText() async {
  final file = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 3000, maxHeight: 3000);
  if (file == null) return null;
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    return (await recognizer.processImage(InputImage.fromFilePath(file.path))).text;
  } finally {
    await recognizer.close();
  }
}

bool _hasCamera(BuildContext context) => switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

/// Wybór źródła dowodu rejestracyjnego: zdjęcie (aparat / plik) albo tekst kodu
/// (np. ze skanera 2D, który „wpisuje” odczytany kod). Zwraca treść zapytania do
/// `POST /api/vehicles/registration` albo `null`.
Future<Map<String, String>?> askRegistration(BuildContext context,
    {PhotoPicker picker = pickPhoto, CodeScanner scanner = scanCode, TextReader reader = readCertificateText}) async {
  final l = context.l;
  final camera = _hasCamera(context);
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l.registrationTitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(l.registrationHint, style: Theme.of(context).textTheme.bodySmall),
        ),
        if (camera)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'scan'),
            child: ListTile(leading: const Icon(Icons.qr_code_scanner), title: Text(l.registrationScan)),
          ),
        if (camera)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'camera'),
            child: ListTile(leading: const Icon(Icons.photo_camera_outlined), title: Text(l.registrationCamera)),
          ),
        if (camera)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'eu'),
            child: ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: Text(l.registrationEu),
              subtitle: Text(l.registrationEuHint),
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'file'),
          child: ListTile(leading: const Icon(Icons.image_outlined), title: Text(l.registrationFile)),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'code'),
          child: ListTile(leading: const Icon(Icons.keyboard_outlined), title: Text(l.registrationCode)),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'scan') {
    final code = await scanner(context);
    return code == null || code.isEmpty ? null : {'code': code};
  }
  if (choice == 'eu') {
    final text = await reader();
    return text == null || text.trim().isEmpty ? null : {'text': text};
  }
  if (choice == 'code') {
    final code = await _askCode(context);
    return code == null || code.trim().isEmpty ? null : {'code': code.trim()};
  }
  final bytes = await picker(choice == 'camera');
  return bytes == null ? null : {'image': base64Encode(bytes)};
}

Future<String?> _askCode(BuildContext context) {
  final l = context.l;
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.registrationCode),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(hintText: l.registrationCodeHint, border: const OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(l.registrationRead)),
      ],
    ),
  );
}

/// Aparat z wyszukiwaniem kodu Aztec – pierwszy odczytany kod wraca do formularza.
class AztecScanScreen extends StatefulWidget {
  const AztecScanScreen({super.key});

  @override
  State<AztecScanScreen> createState() => _AztecScanScreenState();
}

class _AztecScanScreenState extends State<AztecScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.aztec]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(title: Text(l.registrationScan), actions: [
        IconButton(tooltip: l.registrationTorch, icon: const Icon(Icons.flash_on), onPressed: _controller.toggleTorch),
      ]),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            final code = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
            if (code == null || _done) return;
            _done = true;
            Navigator.of(context).pop(code);
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
            child: Text(l.registrationScanHint, style: const TextStyle(color: Colors.white)),
          ),
        ),
      ]),
    );
  }
}
