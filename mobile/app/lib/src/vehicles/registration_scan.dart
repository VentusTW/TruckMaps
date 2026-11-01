import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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

bool _hasCamera(BuildContext context) => switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

/// Wybór źródła dowodu rejestracyjnego: zdjęcie (aparat / plik) albo tekst kodu
/// (np. ze skanera 2D, który „wpisuje” odczytany kod). Zwraca treść zapytania do
/// `POST /api/vehicles/registration` albo `null`.
Future<Map<String, String>?> askRegistration(BuildContext context, {PhotoPicker picker = pickPhoto}) async {
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
            onPressed: () => Navigator.pop(context, 'camera'),
            child: ListTile(leading: const Icon(Icons.photo_camera_outlined), title: Text(l.registrationCamera)),
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
