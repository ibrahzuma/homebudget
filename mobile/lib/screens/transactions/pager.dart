import 'package:flutter/foundation.dart';

import '../../core/models.dart';

/// Page-by-page loader for the API's paginated lists
/// (`{count, page, page_size, has_next, results}`), for infinite scroll.
class Pager<T> extends ChangeNotifier {
  Pager(this._fetch, {this.pageSize = 50});

  final Future<Paged<T>> Function(int page, int pageSize) _fetch;
  final int pageSize;

  final List<T> items = [];

  /// The most recent page, for extras such as `count` and `totals`.
  Paged<T>? last;
  bool loading = false;
  bool hasNext = true;
  Object? error;

  int _page = 0;
  int _generation = 0; // drops responses from superseded refreshes

  bool get isInitialLoading => loading && last == null;
  bool get loaded => last != null;

  /// Reload from page 1. With [clear] the old items disappear immediately
  /// (use when filters change); otherwise they stay until the new page
  /// arrives. Returns the error, if any, so pull-to-refresh can report it.
  Future<Object?> refresh({bool clear = false}) async {
    final gen = ++_generation;
    if (clear) {
      items.clear();
      last = null;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final p = await _fetch(1, pageSize);
      if (gen != _generation) return null;
      items
        ..clear()
        ..addAll(p.results);
      last = p;
      _page = 1;
      hasNext = p.hasNext;
      return null;
    } catch (e) {
      if (gen != _generation) return null;
      error = e;
      return e;
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Fetch the next page unless one is in flight, the end was reached, or
  /// the previous attempt failed (call [retry] for that).
  Future<void> loadMore() async {
    if (loading || !hasNext || error != null || last == null) return;
    final gen = _generation;
    loading = true;
    notifyListeners();
    try {
      final p = await _fetch(_page + 1, pageSize);
      if (gen != _generation) return;
      items.addAll(p.results);
      last = p;
      _page++;
      hasNext = p.hasNext;
    } catch (e) {
      if (gen == _generation) error = e;
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() {
    error = null;
    return last == null ? refresh() : loadMore();
  }

  /// Swap one loaded item in place (e.g. after marking an alert read).
  void replaceWhere(bool Function(T) test, T replacement) {
    final i = items.indexWhere(test);
    if (i < 0) return;
    items[i] = replacement;
    notifyListeners();
  }
}
