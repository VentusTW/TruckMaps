import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'texts.dart';

/// Rozmiar podpisu w pikselach (serwer zmniejsza najwyżej do 600 × 200).
const signatureSize = Size(600, 200);

/// Podpis złożony palcem albo myszą na ekranie: PNG w base64 (`null` – anulowano).
Future<String?> signOnScreen(BuildContext context, String title) => showDialog<String>(
      context: context,
      builder: (_) => _SignatureDialog(title: title),
    );

class _SignatureDialog extends StatefulWidget {
  const _SignatureDialog({required this.title});

  final String title;

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  final _strokes = <List<Offset>>[];
  Size _area = signatureSize;
  bool _busy = false;

  /// Podpis na przezroczystym tle w skali [signatureSize] (serwer podkłada białe tło).
  Future<String> _png() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(signatureSize.width / _area.width, signatureSize.height / _area.height);
    _SignaturePainter(_strokes, Colors.black).paint(canvas, _area);
    final image = await recorder.endRecording().toImage(signatureSize.width.round(), signatureSize.height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return base64Encode(bytes!.buffer.asUint8List());
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    final png = await _png();
    if (mounted) Navigator.of(context).pop(png);
  }

  @override
  Widget build(BuildContext context) {
    final t = DocumentsTexts.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: signatureSize.width,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.signHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: signatureSize.aspectRatio,
            child: LayoutBuilder(builder: (context, constraints) {
              _area = constraints.biggest;
              return DecoratedBox(
                decoration: BoxDecoration(color: Colors.white, border: Border.all(color: scheme.outline)),
                child: GestureDetector(
                  key: const Key('signature-pad'),
                  onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                  onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                  child: CustomPaint(painter: _SignaturePainter(_strokes, Colors.black), size: Size.infinite),
                ),
              );
            }),
          ),
        ]),
      ),
      actions: [
        TextButton(
          key: const Key('signature-clear'),
          onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
          child: Text(t.signClear),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
          key: const Key('signature-ok'),
          onPressed: _strokes.isEmpty || _busy ? null : _accept,
          child: Text(t.signAccept),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, this.color);

  final List<List<Offset>> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(stroke.first, 1.5, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  // Lista kresek zmienia się w miejscu – rysunek zawsze od nowa.
  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
