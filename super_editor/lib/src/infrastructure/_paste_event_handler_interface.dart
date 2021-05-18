import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_editor.dart';
import '_paste_event_handler_no_op.dart' if (dart.library.html) '_paste_event_handler_web.dart';

PasteEventHandler createPlatformPasteEventHandler(PasteDelegate delegate) {
  return PlatformPasteEventHandler(delegate);
}

typedef PasteDelegate = void Function(String content);

abstract class PasteEventHandler {
  void dispose() {}
}
