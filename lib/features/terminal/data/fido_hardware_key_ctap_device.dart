import 'dart:async';
import 'dart:io';

import 'package:fido2/fido2_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fido_nfc_ctap_device.dart';
import 'fido_usb_ctap_device.dart';

class FidoHardwareKeyCtapDevice {
  const FidoHardwareKeyCtapDevice._();

  static const _androidDiscoveryWindow = Duration(seconds: 30);
  static const _usbPollInterval = Duration(milliseconds: 250);

  static Future<CtapDevice> open() async {
    if (Platform.isAndroid) {
      return _openAndroid();
    }
    return FidoNfcCtapDevice.pollAndSelect();
  }

  @visibleForTesting
  static Future<CtapDevice> openAndroidForTesting({
    Duration discoveryWindow = _androidDiscoveryWindow,
    Duration usbPollInterval = _usbPollInterval,
    Future<bool> Function()? isUsbAvailable,
    Future<CtapDevice> Function()? openUsb,
    Future<CtapDevice?> Function()? pollNfc,
    Future<void> Function()? cancelNfcPoll,
  }) => _openAndroid(
    discoveryWindow: discoveryWindow,
    usbPollInterval: usbPollInterval,
    isUsbAvailable: isUsbAvailable,
    openUsb: openUsb,
    pollNfc: pollNfc,
    cancelNfcPoll: cancelNfcPoll,
  );

  static Future<CtapDevice> _openAndroid({
    Duration discoveryWindow = _androidDiscoveryWindow,
    Duration usbPollInterval = _usbPollInterval,
    Future<bool> Function()? isUsbAvailable,
    Future<CtapDevice> Function()? openUsb,
    Future<CtapDevice?> Function()? pollNfc,
    Future<void> Function()? cancelNfcPoll,
  }) async {
    final completer = Completer<CtapDevice>();
    final cancelNfc = cancelNfcPoll ?? FidoNfcCtapDevice.cancelPoll;
    var settled = false;
    var usbDiscoveryDone = false;
    var nfcDiscoveryDone = false;
    Object? usbError;
    StackTrace? usbStackTrace;
    Object? nfcError;
    StackTrace? nfcStackTrace;
    Timer? timeoutTimer;

    void completeWithDevice(CtapDevice device) {
      if (settled) {
        unawaited(close(device, false));
        return;
      }
      settled = true;
      timeoutTimer?.cancel();
      if (device is FidoUsbCtapDevice || !nfcDiscoveryDone) {
        unawaited(cancelNfc());
      }
      completer.complete(device);
    }

    void completeWithError(Object error, StackTrace stackTrace) {
      if (settled) return;
      settled = true;
      timeoutTimer?.cancel();
      unawaited(cancelNfc());
      completer.completeError(error, stackTrace);
    }

    void completeIfBothFinished() {
      if (settled || !usbDiscoveryDone || !nfcDiscoveryDone) return;
      final error =
          usbError ??
          nfcError ??
          StateError('Timed out waiting for a security key.');
      final stackTrace =
          (usbError != null ? usbStackTrace : nfcStackTrace) ??
          StackTrace.current;
      completeWithError(error, stackTrace);
    }

    timeoutTimer = Timer(discoveryWindow, () {
      final error =
          usbError ??
          nfcError ??
          TimeoutException(
            'Timed out waiting for a security key.',
            discoveryWindow,
          );
      final stackTrace =
          (usbError != null ? usbStackTrace : nfcStackTrace) ??
          StackTrace.current;
      completeWithError(error, stackTrace);
    });

    unawaited(
      _pollUsbUntilAvailable(
            discoveryWindow,
            isCancelled: () => settled,
            pollInterval: usbPollInterval,
            isUsbAvailable: isUsbAvailable,
            openUsb: openUsb,
            onError: (error, stackTrace) {
              usbError = error;
              usbStackTrace = stackTrace;
            },
          )
          .then((device) {
            usbDiscoveryDone = true;
            if (device != null) {
              completeWithDevice(device);
            } else {
              completeIfBothFinished();
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            usbDiscoveryDone = true;
            usbError = error;
            usbStackTrace = stackTrace;
            if (error is PlatformException &&
                error.code == 'permission_denied') {
              completeWithError(error, stackTrace);
            } else {
              completeIfBothFinished();
            }
          }),
    );

    unawaited(
      (pollNfc ?? FidoNfcCtapDevice.pollAndSelect)()
          .then((device) {
            nfcDiscoveryDone = true;
            if (device != null) {
              completeWithDevice(device);
            } else {
              completeIfBothFinished();
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            nfcDiscoveryDone = true;
            nfcError = error;
            nfcStackTrace = stackTrace;
            completeIfBothFinished();
          }),
    );

    return completer.future;
  }

  static Future<CtapDevice?> _pollUsbUntilAvailable(
    Duration timeout, {
    required bool Function() isCancelled,
    Duration pollInterval = _usbPollInterval,
    Future<bool> Function()? isUsbAvailable,
    Future<CtapDevice> Function()? openUsb,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!isCancelled() && DateTime.now().isBefore(deadline)) {
      final available =
          await (isUsbAvailable ?? () => FidoUsbCtapDevice.isAvailable)();
      if (isCancelled()) return null;
      if (available) {
        try {
          final device = await (openUsb ?? FidoUsbCtapDevice.open)();
          if (isCancelled()) {
            await close(device, false);
            return null;
          }
          return device;
        } on PlatformException catch (error, stackTrace) {
          if (error.code == 'permission_denied') {
            rethrow;
          }
          if (!isCancelled()) {
            onError?.call(error, stackTrace);
          }
        } catch (error, stackTrace) {
          if (!isCancelled()) {
            onError?.call(error, stackTrace);
          }
        }
      }
      if (isCancelled() || !DateTime.now().isBefore(deadline)) {
        break;
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  static Future<void> close(CtapDevice device, bool ok) {
    if (device is FidoUsbCtapDevice) {
      return device.close();
    }
    if (device is FidoNfcCtapDevice) {
      return device.close(
        successful: ok,
        iosAlertMessage: ok ? 'Security key accepted.' : null,
        iosErrorMessage: ok ? null : 'Security key signing failed.',
      );
    }
    return Future<void>.value();
  }
}
