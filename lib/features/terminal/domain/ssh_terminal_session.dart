abstract interface class SshTerminalSession {
  Stream<List<int>> get stdout;

  Stream<List<int>> get stderr;

  Future<void> get done;

  Future<void> send(List<int> data);

  void resize(int columns, int rows, int pixelWidth, int pixelHeight);

  Future<void> close();
}
