import 'package:supabase_flutter/supabase_flutter.dart';

typedef HostedListingCleanup = Future<void> Function(
  String listingId,
  String ownerId,
  String titleMarker,
);
typedef HostedListingExists = Future<bool> Function(
  String listingId,
  String ownerId,
  String titleMarker,
);
typedef HostedStorageCleanup = Future<void> Function(String path);
typedef HostedStorageExists = Future<bool> Function(String path);

class HostedTestResources {
  final Map<String, ({String ownerId, String titleMarker})> _listings = {};
  final Set<String> _storagePaths = {};

  Set<String> get listingIds => Set.unmodifiable(_listings.keys.toSet());
  Set<String> get storagePaths => Set.unmodifiable(_storagePaths);

  void trackListing({
    required String id,
    required String ownerId,
    required String titleMarker,
  }) {
    if (id.trim().isEmpty ||
        ownerId.trim().isEmpty ||
        titleMarker.trim().isEmpty) {
      throw StateError(
        'A hosted listing requires its ID, owner, and unique title marker.',
      );
    }
    _listings[id] = (ownerId: ownerId, titleMarker: titleMarker.toLowerCase());
  }

  void trackStoragePath(String path) {
    if (path.trim().isEmpty) {
      throw StateError('Cannot track a Storage object without its path.');
    }
    _storagePaths.add(path);
  }

  Future<void> cleanup({
    required HostedStorageCleanup deleteStoragePath,
    required HostedStorageExists storagePathExists,
    required HostedListingCleanup deleteListing,
    required HostedListingExists listingExists,
  }) async {
    final failures = <String>[];

    for (final path in _storagePaths) {
      try {
        await deleteStoragePath(path);
      } catch (error) {
        failures.add('Could not remove test Storage path "$path": $error');
      }
    }
    for (final entry in _listings.entries) {
      try {
        await deleteListing(
          entry.key,
          entry.value.ownerId,
          entry.value.titleMarker,
        );
      } catch (error) {
        failures.add('Could not remove test listing "${entry.key}": $error');
      }
    }

    for (final path in _storagePaths) {
      try {
        if (await storagePathExists(path)) {
          failures.add(
            'Test Storage path still exists after cleanup: "$path".',
          );
        }
      } catch (error) {
        failures.add('Could not verify test Storage path "$path": $error');
      }
    }
    for (final entry in _listings.entries) {
      try {
        if (await listingExists(
          entry.key,
          entry.value.ownerId,
          entry.value.titleMarker,
        )) {
          failures.add(
            'Test listing still exists after cleanup: "${entry.key}".',
          );
        }
      } catch (error) {
        failures.add('Could not verify test listing "${entry.key}": $error');
      }
    }

    if (failures.isNotEmpty) {
      throw StateError(
        'Critical hosted-test cleanup failure:\n${failures.join('\n')}',
      );
    }
  }
}

bool isStorageAuthorizationDenied(Object error) {
  if (error is! StorageException) return false;
  if (error.statusCode == '401' || error.statusCode == '403') return true;
  return error.statusCode == '400' &&
      error.message.toLowerCase().contains('row-level security');
}

Future<void> verifyStorageMutationWasDenied({
  required String operationName,
  required List<int> originalBytes,
  required Future<dynamic> Function() attemptOperation,
  required Future<List<int>> Function() readBytes,
  required Future<void> Function() restoreOriginalBytes,
  bool Function(dynamic result)? isNoopDenialResponse,
}) async {
  Object? operationError;
  dynamic operationResult;
  try {
    operationResult = await attemptOperation();
  } catch (error) {
    operationError = error;
  }

  List<int>? currentBytes;
  Object? readError;
  try {
    currentBytes = await readBytes();
  } catch (error) {
    readError = error;
  }

  final unchanged = _sameBytes(currentBytes, originalBytes);
  if (operationError == null &&
      unchanged &&
      isNoopDenialResponse?.call(operationResult) == true) {
    return;
  }
  if (operationError == null || !unchanged) {
    if (!unchanged) {
      try {
        await restoreOriginalBytes();
        final restoredBytes = await readBytes();
        if (!_sameBytes(restoredBytes, originalBytes)) {
          throw StateError('Restored object bytes do not match the original.');
        }
      } catch (restoreError) {
        throw StateError(
          'CRITICAL: $operationName changed or removed the test-owned object, '
          'and restoration failed. Read error: $readError; '
          'restore error: $restoreError',
        );
      }
    }
    throw StateError(
      'CRITICAL: $operationName was not explicitly denied. '
      'Object unchanged: $unchanged; operation error: $operationError; '
      'read error: $readError. Any changed bytes were restored.',
    );
  }

  if (isStorageAuthorizationDenied(operationError)) return;
  throw StateError(
    '$operationName left the test object unchanged, but its failure does not '
    'confirm Storage authorization was enforced: $operationError',
  );
}

bool _sameBytes(List<int>? left, List<int> right) {
  if (left == null || left.length != right.length) return false;
  for (var index = 0; index < right.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
