abstract interface class SshTerminalSession {
  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<void> get done;

  Future<void> send(List<int> data);

  void resize(int columns, int rows, int pixelWidth, int pixelHeight);

  Future<void> close();

  /// Runs [command] on the same connection over a fresh exec channel and
  /// returns the captured stdout decoded as UTF-8 (malformed sequences are
  /// tolerated), or null on timeout / error.
  ///
  /// Only transport sessions backed by a real SSH client support this;
  /// sessions without an exec channel throw [UnsupportedError].
  Future<String?> exec(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    throw UnsupportedError('exec is not supported by this session type.');
  }
}
