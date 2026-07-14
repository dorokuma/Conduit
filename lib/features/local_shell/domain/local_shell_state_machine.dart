import 'package:conduit/features/local_shell/domain/local_shell_event.dart';
import 'package:conduit/features/local_shell/domain/local_shell_state.dart';

class LocalShellStateMachine {
  const LocalShellStateMachine();

  LocalShellState reduce(LocalShellState state, LocalShellEvent event) {
    switch (event) {
      case EnvironmentReady(:final version, :final diskUsageBytes):
        return LocalShellState(
          stage: LocalShellStage.ready,
          installedVersion: version,
          diskUsageBytes: diskUsageBytes,
        );

      case EnvironmentMissing():
        return LocalShellState.notInstalled;

      case InstallRequested(:final distroName):
        return LocalShellState(
          stage: LocalShellStage.downloading,
          progress: 0,
          message: 'Downloading $distroName…',
        );

      case DownloadProgressed(:final progress):
        if (state.stage != LocalShellStage.downloading) return state;
        return state.copyWith(progress: progress.clamp(0.0, 1.0));

      case DownloadFinished():
        if (state.stage != LocalShellStage.downloading) return state;
        return const LocalShellState(
          stage: LocalShellStage.extracting,
          message: 'Unpacking root filesystem… (this can take a few minutes)',
        );

      case ExtractFinished():
        if (state.stage != LocalShellStage.extracting) return state;
        return const LocalShellState(
          stage: LocalShellStage.configuring,
          message: 'Running first-time setup…',
        );

      case ConfigureStarted():
        if (state.stage != LocalShellStage.configuring) return state;
        return state.copyWith(clearProgress: true);

      case InstallSucceeded(:final version, :final diskUsageBytes):
        return LocalShellState(
          stage: LocalShellStage.ready,
          installedVersion: version,
          diskUsageBytes: diskUsageBytes,
        );

      case InstallFailed(:final error):
        return LocalShellState(stage: LocalShellStage.failed, error: error);

      case ResetRequested():
        return LocalShellState.notInstalled;
    }
  }
}
