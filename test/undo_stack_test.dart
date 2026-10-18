import 'package:flutter_test/flutter_test.dart';
import 'package:open_video_editor/engine/undo_history.dart';

void main() {
  group('UndoStack', () {
    test('starts empty', () {
      final h = UndoStack<String>();
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.undo('x'), isNull);
      expect(h.redo('x'), isNull);
    });

    test('push/undo/redo round-trip', () {
      final h = UndoStack<String>();
      h.push('a');
      h.push('b');
      expect(h.canUndo, isTrue);
      // undo('c') stashes 'c' on the redo stack and restores 'b'.
      expect(h.undo('c'), 'b');
      expect(h.undo('b'), 'a');
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isTrue);
      expect(h.redo('a'), 'b');
      expect(h.redo('b'), 'c');
      expect(h.canRedo, isFalse);
    });

    test('push clears the redo stack', () {
      final h = UndoStack<String>();
      h.push('a');
      h.undo('b');
      expect(h.canRedo, isTrue);
      h.push('c');
      expect(h.canRedo, isFalse);
    });

    test('respects the limit', () {
      final h = UndoStack<int>(limit: 3);
      for (var i = 0; i < 5; i++) {
        h.push(i);
      }
      expect(h.undoCount, 3);
      expect(h.undo(99), 4);
      expect(h.undo(99), 3);
      expect(h.undo(99), 2);
      expect(h.canUndo, isFalse);
    });

    test('clear empties both stacks', () {
      final h = UndoStack<String>();
      h.push('a');
      h.undo('b');
      h.clear();
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
    });
  });
}
