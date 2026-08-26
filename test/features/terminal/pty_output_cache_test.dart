import 'dart:typed_data';

import 'package:conduit/features/terminal/data/pty_output_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retains recent bytes and reports total writes', () {
    final cache = PtyOutputCache(capacity: 4);
    cache.append(Uint8List.fromList([1, 2, 3]));
    cache.append(Uint8List.fromList([4, 5, 6]));

    expect(cache.totalWritten, 6);
    expect(cache.length, 4);
    expect(cache.readLast(2), [5, 6]);
    expect(cache.readRange(0, 4), [3, 4, 5, 6]);
  });

  test('handles wrapped reads and oversized writes', () {
    final cache = PtyOutputCache(capacity: 4);
    cache.append(Uint8List.fromList([1, 2, 3]));
    cache.append(Uint8List.fromList([4, 5]));
    expect(cache.readRange(1, 3), [3, 4, 5]);

    cache.append(Uint8List.fromList([6, 7, 8, 9, 10]));
    expect(cache.readLast(10), [7, 8, 9, 10]);
    expect(cache.totalWritten, 10);
  });
}
