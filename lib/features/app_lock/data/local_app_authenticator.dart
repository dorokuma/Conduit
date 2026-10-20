import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class LocalAppAuthenticator implements AppAuthenticator {
  LocalAppAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> canAuthenticate() async {
    try {
      return await _localAuthentication.isDeviceSupported();
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<AppAuthenticationResult> authenticate() async {
    try {
      final authenticated = await _localAuthentication.authenticate(
        localizedReason: 'Unlock Conduit to access saved SSH machines.',
      );
      return authenticated
          ? AppAuthenticationResult.success
          : AppAuthenticationResult.cancelled;
    } on LocalAuthException catch (error) {
      return _mapException(error);
    } on PlatformException {
      return AppAuthenticationResult.unavailable;
    }
  }

  /// Maps plugin errors to the lock screen outcome.
  ///
  /// A device with biometric hardware but no enrolled credentials reports
  /// [LocalAuthExceptionCode.noCredentialsSet]; treating that as a plain
  /// cancellation would keep the lock screen retrying forever with no way to
  /// continue, so it has to surface as [AppAuthenticationResult.unavailable].
  AppAuthenticationResult _mapException(LocalAuthException error) {
    switch (error.code) {
      case LocalAuthExceptionCode.noCredentialsSet:
      case LocalAuthExceptionCode.noBiometricHardware:
      case LocalAuthExceptionCode.noBiometricsEnrolled:
      case LocalAuthExceptionCode.uiUnavailable:
        return AppAuthenticationResult.unavailable;
      case LocalAuthExceptionCode.authInProgress:
      case LocalAuthExceptionCode.userCanceled:
      case LocalAuthExceptionCode.timeout:
      case LocalAuthExceptionCode.systemCanceled:
      case LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
      case LocalAuthExceptionCode.temporaryLockout:
      case LocalAuthExceptionCode.biometricLockout:
      case LocalAuthExceptionCode.userRequestedFallback:
      case LocalAuthExceptionCode.deviceError:
      case LocalAuthExceptionCode.unknownError:
        return AppAuthenticationResult.cancelled;
    }
  }
}
