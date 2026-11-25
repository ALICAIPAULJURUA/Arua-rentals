import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/hosted_test_resources.dart';

void main() {
  test('cleanup only visits and verifies tracked hosted resources', () async {
    final resources = HostedTestResources()
      ..trackListing(
        id: 'listing-test-id',
        ownerId: 'owner-test-id',
        titleMarker: 'hosted-test',
      )
      ..trackStoragePath('owner-test-id/listing-test-id/test.png');
    final deleted = <String>[];
    final checked = <String>[];

    await resources.cleanup(
      deleteStoragePath: (path) async {
        deleted.add(path);
      },
      storagePathExists: (path) async {
        checked.add(path);
        return false;
      },
      deleteListing: (id, ownerId, marker) async {
        deleted.add('$id|$ownerId|$marker');
      },
      listingExists: (id, ownerId, marker) async {
        checked.add('$id|$ownerId|$marker');
        return false;
      },
    );

    expect(deleted, [
      'owner-test-id/listing-test-id/test.png',
      'listing-test-id|owner-test-id|hosted-test',
    ]);
    expect(checked, [
      'owner-test-id/listing-test-id/test.png',
      'listing-test-id|owner-test-id|hosted-test',
    ]);
  });

  test(
    'cleanup reports remaining exact records after attempting all deletes',
    () async {
      final resources = HostedTestResources()
        ..trackListing(
          id: 'listing-test-id',
          ownerId: 'owner-test-id',
          titleMarker: 'hosted-test',
        )
        ..trackStoragePath('owner-test-id/listing-test-id/test.png');
      final deleted = <String>[];

      await expectLater(
        resources.cleanup(
          deleteStoragePath: (path) async {
            deleted.add(path);
          },
          storagePathExists: (path) async => true,
          deleteListing: (id, ownerId, marker) async {
            deleted.add('$id|$ownerId|$marker');
          },
          listingExists: (id, ownerId, marker) async => true,
        ),
        throwsA(
          isA<StateError>()
              .having((error) => error.message, 'message', contains('Critical'))
              .having(
                (error) => error.message,
                'message',
                contains('listing-test-id'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('test.png'),
              ),
        ),
      );
      expect(deleted, hasLength(2));
    },
  );

  test('Storage authorization error confirms denied mutation', () async {
    final original = [1, 2, 3];
    var restoreCalls = 0;

    await verifyStorageMutationWasDenied(
      operationName: 'cross-owner upload',
      originalBytes: original,
      attemptOperation: () async {
        throw const StorageException(
          'new row violates row-level security policy',
          statusCode: '403',
        );
      },
      readBytes: () async => original,
      restoreOriginalBytes: () async {
        restoreCalls++;
      },
    );

    expect(restoreCalls, 0);
  });

  test(
    'successful unauthorized Storage mutation restores exact test object',
    () async {
      final original = [1, 2, 3];
      var bytes = [9, 8, 7];
      var restoreCalls = 0;

      await expectLater(
        verifyStorageMutationWasDenied(
          operationName: 'cross-owner overwrite',
          originalBytes: original,
          attemptOperation: () async => null,
          readBytes: () async => bytes,
          restoreOriginalBytes: () async {
            restoreCalls++;
            bytes = original;
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('CRITICAL'),
          ),
        ),
      );
      expect(bytes, original);
      expect(restoreCalls, 1);
    },
  );

  test(
    'empty Storage delete response with unchanged bytes is a denied no-op',
    () async {
      final original = [1, 2, 3];

      await verifyStorageMutationWasDenied(
        operationName: 'cross-owner delete',
        originalBytes: original,
        attemptOperation: () async => <Object>[],
        readBytes: () async => original,
        restoreOriginalBytes: () async {},
        isNoopDenialResponse: (result) => result is List && result.isEmpty,
      );
    },
  );
}
