import 'dart:math';

class IdGen {
  IdGen._();

  static final Random _rng = Random();
  static int _counter = 0;

  static String next([String prefix = 'id']) {
    _counter++;
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = _rng.nextInt(1 << 32).toRadixString(36);
    return '${prefix}_${ts}_${rand}_$_counter';
  }
}