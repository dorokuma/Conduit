import 'dart:typed_data';

/// Bounded storage for the recent raw output of a PTY.
///
/// Offsets are relative to the retained data: once the capacity is reached,
/// the beginning of the range moves forward. The implementation deliberately
/// keeps the storage contiguous when read; PTY chunks are small compared with
/// the cache and this keeps reads predictable for terminal reconstruction.
class PtyOutputCache {
  PtyOutputCache({this.capacity = 256 * 1024})
    : assert(capacity > 0),
      _buffer = Uint8List(capacity);

  final int capacity;
  final Uint8List _buffer;
  int _start = 0;
  int _length = 0;
  int _totalWritten = 0;

  int get totalWritten => _totalWritten;
  int get length => _length;
  int get retainedStart => _totalWritten - _length;

  void append(Uint8List data) {
    if (data.isEmpty) return;
    _totalWritten += data.length;
    if (data.length >= capacity) {
      _buffer.setRange(0, capacity, data, data.length - capacity);
      _start = 0;
      _length = capacity;
      return;
    }
    final overflow = (_length + data.length) - capacity;
    if (overflow > 0) {
      _start = (_start + overflow) % capacity;
      _length -= overflow;
    }
    final end = (_start + _length) % capacity;
    final first = data.length <= capacity - end ? data.length : capacity - end;
    _buffer.setRange(end, end + first, data, 0);
    if (first < data.length) {
      _buffer.setRange(0, data.length - first, data, first);
    }
    _length += data.length;
  }

  Uint8List readLast(int bytes) {
    if (bytes <= 0 || _length == 0) return Uint8List(0);
    return readRange(
      _length - (bytes < _length ? bytes : _length),
      bytes < _length ? bytes : _length,
    );
  }

  /// Reads [length] bytes from the retained range, clamping out-of-range
  /// requests rather than exposing the discarded portion of the stream.
  Uint8List readRange(int offset, int length) {
    final start = offset.clamp(0, _length);
    final count = length.clamp(0, _length - start);
    final result = Uint8List(count);
    if (count == 0) return result;
    final physical = (_start + start) % capacity;
    final first = count <= capacity - physical ? count : capacity - physical;
    result.setRange(0, first, _buffer, physical);
    if (first < count) result.setRange(first, count, _buffer, 0);
    return result;
  }

  void clear() {
    _start = 0;
    _length = 0;
    _totalWritten = 0;
  }
}
