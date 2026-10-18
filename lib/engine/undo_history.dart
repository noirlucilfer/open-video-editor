/// Tiny undo/redo stack for immutable project snapshots.
///
/// The editor pushes the pre-change [TimelineProject] on every mutation;
/// drag gestures push once per gesture (see the drag handlers in
/// editor_screen.dart), so one undo step reverts one user action.
class UndoStack<T> {
  UndoStack({this.limit = 50});

  final int limit;
  final List<T> _undo = [];
  final List<T> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  int get undoCount => _undo.length;

  void push(T state) {
    _undo.add(state);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// Returns the state to restore, or null when there is nothing to undo.
  T? undo(T current) {
    if (!canUndo) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  /// Returns the state to restore, or null when there is nothing to redo.
  T? redo(T current) {
    if (!canRedo) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
