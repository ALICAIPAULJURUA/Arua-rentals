import 'dart:io';
import 'dart:math';

import 'package:arua_rentals/core/config/supabase_config.dart';
import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:arua_rentals/features/listings/data/media_uploader.dart';
import 'package:arua_rentals/features/listings/data/supabase_listings_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/hosted_test_resources.dart';

const _runHostedTests = bool.fromEnvironment(
  'RUN_SUPABASE_HOSTED_TESTS',
  defaultValue: false,
);
const _hostedWriteAcknowledgement = 'I_APPROVE_HOSTED_TEST_WRITES';

final _environment = Platform.environment;
final _resources = HostedTestResources();

String _freshSignupEmail() {
  final base = _requiredEnvironment('SUPABASE_TEST_NEW_USER_EMAIL');
  final at = base.lastIndexOf('@');
  if (at <= 0 || at == base.length - 1) {
    throw StateError('SUPABASE_TEST_NEW_USER_EMAIL must be a valid email.');
  }
  final marker = _requiredEnvironment('SUPABASE_TEST_ACCOUNT_MARKER');
  final localPart = base.substring(0, at);
  final domain = base.substring(at + 1);
  final uniqueSuffix =
      '${marker}_hosted_${DateTime.now().toUtc().microsecondsSinceEpoch}';
  return '$localPart+$uniqueSuffix@$domain';
}

String _newUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

void _trackListing({
  required String id,
  required String ownerId,
  required String titleMarker,
}) {
  _resources.trackListing(id: id, ownerId: ownerId, titleMarker: titleMarker);
  debugPrint('Tracked hosted test listing ID: $id');
}

void _trackStoragePath(String path) {
  _resources.trackStoragePath(path);
  debugPrint('Tracked hosted test Storage path: $path');
}

String _requiredEnvironment(String name) {
  final value = _environment[name]?.trim();
  if (value == null || value.isEmpty) {
    throw StateError('$name must be set in the test process environment.');
  }
  return value;
}

void _validateHostedTestSafety() {
  final expectedHost = _requiredEnvironment('SUPABASE_EXPECTED_PROJECT_HOST')
      .toLowerCase();
  final actualHost = Uri.parse(SupabaseConfig.projectUrl).host.toLowerCase();
  if (actualHost != expectedHost) {
    throw StateError(
      'Configured Supabase host does not match SUPABASE_EXPECTED_PROJECT_HOST.',
    );
  }

  final marker = _requiredEnvironment('SUPABASE_TEST_ACCOUNT_MARKER')
      .toLowerCase();
  if (marker.length < 6) {
    throw StateError(
      'SUPABASE_TEST_ACCOUNT_MARKER must be at least 6 characters.',
    );
  }

  final emails = [
    'LANDLORD',
    'SECOND_LANDLORD',
    'TENANT',
    'ADMIN',
    'NEW_USER',
  ].map((role) => _requiredEnvironment('SUPABASE_TEST_${role}_EMAIL')).toList();
  final normalizedEmails = emails.map((email) => email.toLowerCase()).toSet();
  if (normalizedEmails.length != emails.length) {
    throw StateError(
      'Each hosted-test role must use a separate email address.',
    );
  }
  if (emails.any(
    (email) => !email.split('@').first.toLowerCase().contains(marker),
  )) {
    throw StateError(
      'Every hosted-test email local part must contain '
      'SUPABASE_TEST_ACCOUNT_MARKER.',
    );
  }
  final signupEmail = _freshSignupEmail();
  if (!signupEmail.toLowerCase().contains(marker)) {
    throw StateError('Generated signup email is missing the test marker.');
  }

  if (_requiredEnvironment('SUPABASE_HOSTED_TEST_WRITE_ACK') !=
      _hostedWriteAcknowledgement) {
    throw StateError(
      'Set SUPABASE_HOSTED_TEST_WRITE_ACK only after approving hosted test '
      'writes and cleanup.',
    );
  }
}

SupabaseClient _newClient() => SupabaseClient(
  SupabaseConfig.projectUrl,
  SupabaseConfig.publishableKey,
  authOptions: const AuthClientOptions(
    autoRefreshToken: false,
    authFlowType: AuthFlowType.implicit,
  ),
);

Future<SupabaseClient> _signIn(String role) async {
  final client = _newClient();
  try {
    await client.auth.signInWithPassword(
      email: _requiredEnvironment('SUPABASE_TEST_${role}_EMAIL'),
      password: _requiredEnvironment('SUPABASE_TEST_${role}_PASSWORD'),
    );
    return client;
  } catch (_) {
    await client.dispose();
    rethrow;
  }
}

Listing _testListing({
  String id = '',
  required String ownerId,
  required String category,
  required String area,
  required String title,
  List<String> imageUrls = const [],
}) => Listing(
  id: id,
  ownerId: ownerId,
  ownerName: '',
  ownerPhone: '+256701234567',
  type: ListingType.property,
  category: category,
  title: title,
  description: 'Hosted integration test listing; safe to remove.',
  priceUgx: 100000,
  priceUnit: ListingPriceUnit.month,
  area: area,
  amenities: const [],
  imageUrls: imageUrls,
  thumbnailUrl: imageUrls.isEmpty ? '' : imageUrls.first,
  searchKeywords: const [],
  status: ListingStatus.pending,
  ratingAvg: 0,
  ratingCount: 0,
  isFeatured: false,
);

Future<void> _expectPostgrestDenied(Future<dynamic> operation) async {
  await expectLater(operation, throwsA(isA<PostgrestException>()));
}

bool _isProfileAuthorizationError(PostgrestException error) =>
    error.code == '42501';

Future<void> _expectProfileFieldProtected({
  required SupabaseClient client,
  required SupabaseClient adminClient,
  required String field,
  required Object? attemptedValue,
  required Object? originalValue,
  required String userId,
}) async {
  Object? operationError;
  Map<String, dynamic>? updated;
  try {
    updated = await client
        .from('profiles')
        .update({field: attemptedValue})
        .eq('id', userId)
        .select('id')
        .maybeSingle();
  } catch (error) {
    operationError = error;
  }

  final current = await client
      .from('profiles')
      .select(field)
      .eq('id', userId)
      .single();
  final currentValue = current[field];
  if (updated != null || currentValue != originalValue) {
    try {
      await adminClient
          .from('profiles')
          .update({field: originalValue})
          .eq('id', userId)
          .select('id')
          .single();
    } catch (restoreError) {
      throw StateError(
        'CRITICAL: unauthorized profile update changed $field and restoration '
        'failed: $restoreError',
      );
    }
    final restored = await client
        .from('profiles')
        .select(field)
        .eq('id', userId)
        .single();
    if (restored[field] != originalValue) {
      throw StateError(
        'CRITICAL: unauthorized profile update changed $field and the original '
        'value could not be verified after restoration.',
      );
    }
    throw StateError(
      'CRITICAL: unauthorized update of profile field $field succeeded. '
      'The original value was restored.',
    );
  }
  if (operationError == null) return;
  if (operationError is PostgrestException &&
      _isProfileAuthorizationError(operationError)) {
    return;
  }
  throw StateError(
    'Profile field $field remained unchanged, but the operation did not '
    'return a recognized authorization denial: $operationError',
  );
}

Future<void> _cleanupTrackedResources({
  required SupabaseClient? landlordClient,
  required SupabaseClient? adminClient,
}) async {
  if (adminClient == null || landlordClient == null) return;

  Future<void> deleteStoragePath(String path) async {
    await landlordClient.storage.from('listing-images').remove([path]);
  }

  Future<bool> storagePathExists(String path) async {
    final parts = path.split('/');
    if (parts.length < 2) {
      throw StateError('Tracked Storage path is not owner-scoped: $path');
    }
    final parent = parts.sublist(0, parts.length - 1).join('/');
    final filename = parts.last;
    final objects = await landlordClient.storage
        .from('listing-images')
        .list(path: parent);
    return objects.any((object) => object.name == filename);
  }

  Future<void> deleteListing(
    String id,
    String ownerId,
    String titleMarker,
  ) async {
    final existing = await adminClient
        .from('listings')
        .select('id, owner_id, title_lower')
        .eq('id', id)
        .maybeSingle();
    if (existing == null) return;
    if (existing['owner_id'] != ownerId ||
        !(existing['title_lower'] as String).startsWith(titleMarker)) {
      throw StateError(
        'Tracked listing "$id" no longer matches its test owner/title marker; '
        'refusing to delete it.',
      );
    }
    await adminClient
        .from('listings')
        .delete()
        .eq('id', id)
        .eq('owner_id', ownerId)
        .eq('title_lower', existing['title_lower']);
  }

  Future<bool> listingExists(
    String id,
    String ownerId,
    String titleMarker,
  ) async {
    final existing = await adminClient
        .from('listings')
        .select('id, owner_id, title_lower')
        .eq('id', id)
        .maybeSingle();
    if (existing == null) return false;
    if (existing['owner_id'] != ownerId ||
        !(existing['title_lower'] as String).startsWith(titleMarker)) {
      throw StateError(
        'Listing ID "$id" exists but is no longer the tracked test resource.',
      );
    }
    return true;
  }

  await _resources.cleanup(
    deleteStoragePath: deleteStoragePath,
    storagePathExists: storagePathExists,
    deleteListing: deleteListing,
    listingExists: listingExists,
  );
}

void main() {
  final enabled = _runHostedTests;
  SupabaseClient? landlord;
  SupabaseClient? secondLandlord;
  SupabaseClient? tenant;
  SupabaseClient? admin;

  setUpAll(() async {
    if (!enabled) return;
    SupabaseConfig.validate();
    _validateHostedTestSafety();
    landlord = await _signIn('LANDLORD');
    secondLandlord = await _signIn('SECOND_LANDLORD');
    tenant = await _signIn('TENANT');
    admin = await _signIn('ADMIN');
    if (admin!.auth.currentUser?.appMetadata['admin'] != true) {
      throw StateError(
        'The dedicated hosted-test administrator needs its trusted admin claim.',
      );
    }
  });

  tearDownAll(() async {
    if (enabled) {
      try {
        await _cleanupTrackedResources(
          landlordClient: landlord,
          adminClient: admin,
        );
      } finally {
        await landlord?.dispose();
        await secondLandlord?.dispose();
        await tenant?.dispose();
        await admin?.dispose();
      }
      return;
    }
    await landlord?.dispose();
    await secondLandlord?.dispose();
    await tenant?.dispose();
    await admin?.dispose();
  });

  group(
    'hosted Supabase authentication and listing operations',
    skip: enabled ? false : 'Set RUN_SUPABASE_HOSTED_TESTS=true to run against the hosted project.',
    () {
      tearDown(() async {
        if (enabled) {
          await _cleanupTrackedResources(
            landlordClient: landlord,
            adminClient: admin,
          );
        }
      });

      test('valid and invalid credentials behave correctly', () async {
        expect(landlord!.auth.currentUser, isNotNull);

        final invalidClient = _newClient();
        addTearDown(invalidClient.dispose);
        await expectLater(
          invalidClient.auth.signInWithPassword(
            email: _requiredEnvironment('SUPABASE_TEST_LANDLORD_EMAIL'),
            password:
                '${_requiredEnvironment('SUPABASE_TEST_LANDLORD_PASSWORD')}_invalid',
          ),
          throwsA(isA<AuthException>()),
        );
        expect(invalidClient.auth.currentUser, isNull);
      });

      test('tenant cannot create listings or read another owner profile', () async {
        final tenantId = tenant!.auth.currentUser!.id;
        final profile = await tenant!
            .from('profiles')
            .select('role')
            .eq('id', tenantId)
            .single();
        expect(profile['role'], 'tenant');
        await _expectPostgrestDenied(
          tenant!
              .from('profiles')
              .select()
              .eq('id', landlord!.auth.currentUser!.id)
              .single(),
        );

        final category = await tenant!
            .from('categories')
            .select('id')
            .eq('is_active', true)
            .order('sort_order')
            .limit(1)
            .single();
        final area = await tenant!
            .from('areas')
            .select('id')
            .eq('is_active', true)
            .order('sort_order')
            .limit(1)
            .single();
        final attemptedId = _newUuid();
        final marker =
            'hosted-unauthorized-${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final existing = await admin!
            .from('listings')
            .select('id')
            .eq('id', attemptedId)
            .maybeSingle();
        expect(existing, isNull);
        Object? operationError;
        Map<String, dynamic>? inserted;
        var createdRowFound = false;
        try {
          inserted = await tenant!
              .from('listings')
              .insert({
                'id': attemptedId,
                'owner_id': tenantId,
                'type': 'property',
                'category_id': category['id'],
                'area_id': area['id'],
                'title': '$marker unauthorized listing',
                'title_lower': '$marker unauthorized listing',
                'description': 'Hosted RLS test; safe to remove.',
                'price_ugx': 100000,
                'price_unit': 'month',
                'status': 'pending',
                'search_prefixes': <String>[],
              })
              .select('id')
              .maybeSingle();
        } catch (error) {
          operationError = error;
        } finally {
          final rowAtAttemptedId = await admin!
              .from('listings')
              .select('id, owner_id, title_lower')
              .eq('id', attemptedId)
              .maybeSingle();
          if (rowAtAttemptedId != null &&
              rowAtAttemptedId['owner_id'] == tenantId &&
              rowAtAttemptedId['title_lower'] ==
                  '$marker unauthorized listing') {
            createdRowFound = true;
            _trackListing(
              id: attemptedId,
              ownerId: tenantId,
              titleMarker: marker,
            );
          } else if (rowAtAttemptedId != null) {
            throw StateError(
              'The preflight-checked listing ID is occupied by a row that '
              'does not match this test; refusing to alter it.',
            );
          }
        }
        if (inserted != null || createdRowFound) {
          throw StateError(
            'CRITICAL RLS FAILURE: a tenant listing insert succeeded. '
            'The exact created row was tracked for cleanup.',
          );
        }
        if (operationError is PostgrestException &&
            operationError.code == '42501') {
          return;
        }
        if (operationError == null) {
          throw StateError(
            'Tenant insert returned no row and no authorization error; '
            'the result is inconclusive.',
          );
        }
        throw StateError(
          'Tenant insert did not return the expected RLS authorization '
          'error (42501): $operationError',
        );
      });

      test('fresh registration creates an unprivileged profile', () async {
        final email = _freshSignupEmail();
        debugPrint('Hosted signup test user: $email');
        final password = _requiredEnvironment(
          'SUPABASE_TEST_NEW_USER_PASSWORD',
        );
        final registrationClient = _newClient();
        addTearDown(registrationClient.dispose);

        final response = await registrationClient.auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: SupabaseConfig.authRedirectUrl,
          data: {
            'full_name': 'Hosted Integration Test',
            'phone': '+256701234567',
            'requested_role': 'landlord',
          },
        );
        expect(response.user, isNotNull);
        expect(
          response.session,
          isNull,
          reason:
              'Email confirmation is enabled for this project; signup must '
              'not be treated as a confirmed session.',
        );

        final profile = await admin!
            .from('profiles')
            .select('id, full_name, role, account_status')
            .eq('id', response.user!.id)
            .single();
        expect(profile['id'], response.user!.id);
        expect(profile['full_name'], 'Hosted Integration Test');
        expect(profile['role'], 'tenant');
        expect(profile['account_status'], 'active');
      });

      test(
        'profiles can be updated by owner but not assigned privileged fields',
        () async {
          final user = landlord!.auth.currentUser!;
          final original = await landlord!
              .from('profiles')
              .select('full_name, phone, role, account_status')
              .eq('id', user.id)
              .single();
          final temporaryName =
              'Hosted test ${DateTime.now().toUtc().microsecondsSinceEpoch}';

          try {
            final updated = await landlord!
                .from('profiles')
                .update({'full_name': temporaryName})
                .eq('id', user.id)
                .select('full_name')
                .single();
            expect(updated['full_name'], temporaryName);
          } finally {
            try {
              await landlord!
                  .from('profiles')
                  .update({'full_name': original['full_name']})
                  .eq('id', user.id)
                  .select('id')
                  .single();
            } catch (error) {
              throw StateError(
                'Critical: failed to restore the dedicated landlord profile '
                'name: $error',
              );
            }
            final restored = await landlord!
                .from('profiles')
                .select('full_name, phone')
                .eq('id', user.id)
                .single();
            if (restored['full_name'] != original['full_name'] ||
                restored['phone'] != original['phone']) {
              throw StateError(
                'Critical: dedicated landlord profile restoration could not '
                'be verified.',
              );
            }
          }

          await _expectProfileFieldProtected(
            client: landlord!,
            adminClient: admin!,
            field: 'role',
            attemptedValue: 'admin',
            originalValue: original['role'],
            userId: user.id,
          );
          await _expectProfileFieldProtected(
            client: landlord!,
            adminClient: admin!,
            field: 'account_status',
            attemptedValue: 'suspended',
            originalValue: original['account_status'],
            userId: user.id,
          );
        },
      );

      test(
        'password recovery request is accepted for the dedicated account',
        () async {
          await landlord!.auth.resetPasswordForEmail(
            _requiredEnvironment('SUPABASE_TEST_LANDLORD_EMAIL'),
            redirectTo: SupabaseConfig.authRedirectUrl,
          );
        },
      );

      test('logout clears the authenticated session', () async {
        final client = await _signIn('TENANT');
        addTearDown(client.dispose);
        expect(client.auth.currentUser, isNotNull);
        await client.auth.signOut();
        expect(client.auth.currentUser, isNull);
      });

      test(
        'landlord CRUD, moderation, filters and foreign-owner access',
        () async {
          final ownerId = landlord!.auth.currentUser!.id;
          final ownerRepo = SupabaseListingsRepository(client: landlord!);
          final adminRepo = SupabaseListingsRepository(client: admin!);
          final publicClient = _newClient();
          addTearDown(publicClient.dispose);
          final category = await landlord!
              .from('categories')
              .select('name')
              .eq('is_active', true)
              .order('sort_order')
              .limit(1)
              .single();
          final area = await landlord!
              .from('areas')
              .select('name')
              .eq('is_active', true)
              .order('sort_order')
              .limit(1)
              .single();
          final categoryName = category['name'] as String;
          final areaName = area['name'] as String;
          final searchToken =
              'hosted${DateTime.now().toUtc().microsecondsSinceEpoch}';

          Future<Listing> createTestListing(int index) async {
            final id = _newUuid();
            final existing = await admin!
                .from('listings')
                .select('id')
                .eq('id', id)
                .maybeSingle();
            if (existing != null) {
              throw StateError(
                'Generated listing ID already exists; refusing to reuse it.',
              );
            }
            final listing = await ownerRepo.create(
              _testListing(
                id: id,
                ownerId: ownerId,
                category: categoryName,
                area: areaName,
                title: '$searchToken property $index',
                imageUrls: index == 2
                    ? const ['https://images.example.test/external.jpg']
                    : const [],
              ),
              onCreated: (id) => _trackListing(
                id: id,
                ownerId: ownerId,
                titleMarker: searchToken,
              ),
            );
            return listing;
          }

          try {
            final first = await createTestListing(1);
            final second = await createTestListing(2);
            expect(first.status, ListingStatus.pending);
            expect(second.status, ListingStatus.pending);
            expect(second.imageUrls, [
              'https://images.example.test/external.jpg',
            ]);

            final edited = await ownerRepo.update(
              first.copyWith(title: '$searchToken edited property'),
            );
            expect(edited.title, '$searchToken edited property');
            expect(edited.status, ListingStatus.pending);

            Object? foreignUpdateError;
            Map<String, dynamic>? foreignUpdate;
            try {
              foreignUpdate = await secondLandlord!
                  .from('listings')
                  .update({'title': 'Foreign owner modification'})
                  .eq('id', first.id)
                  .select('id')
                  .maybeSingle();
            } catch (error) {
              foreignUpdateError = error;
            }
            final afterForeignUpdate = await ownerRepo.getById(first.id);
            if (foreignUpdate != null ||
                afterForeignUpdate?.title != first.title) {
              try {
                await ownerRepo.update(first.copyWith(title: first.title));
              } catch (restoreError) {
                throw StateError(
                  'CRITICAL: cross-owner listing update succeeded and the '
                  'test-owned listing could not be restored: $restoreError',
                );
              }
              throw StateError(
                'CRITICAL RLS FAILURE: cross-owner listing update succeeded. '
                'The original test listing title was restored.',
              );
            }
            if (foreignUpdateError != null &&
                (foreignUpdateError is! PostgrestException ||
                    foreignUpdateError.code != '42501')) {
              throw StateError(
                'Cross-owner update failed without the expected RLS denial '
                '(42501): '
                '$foreignUpdateError',
              );
            }

            await adminRepo.setStatus(first.id, ListingStatus.approved);
            await adminRepo.setStatus(second.id, ListingStatus.approved);
            final publicPage =
                await SupabaseListingsRepository(client: publicClient)
                    .getApprovedListings(
                      category: categoryName,
                      area: areaName,
                      keyword: searchToken,
                      limit: 1,
                    );
            expect(publicPage.items, hasLength(1));
            expect(publicPage.nextCursor, isNotNull);
            final nextPage =
                await SupabaseListingsRepository(client: publicClient)
                    .getApprovedListings(
                      category: categoryName,
                      area: areaName,
                      keyword: searchToken,
                      limit: 1,
                      startAfter: publicPage.nextCursor,
                    );
            expect(nextPage.items, hasLength(1));
            expect(
              {publicPage.items.single.id, nextPage.items.single.id},
              {first.id, second.id},
            );

            final details = await SupabaseListingsRepository(
              client: publicClient,
            ).getById(first.id);
            expect(details?.status, ListingStatus.approved);

            await adminRepo.setStatus(
              second.id,
              ListingStatus.rejected,
              rejectionReason: 'Hosted test moderation.',
            );
            final publicDetails = await SupabaseListingsRepository(
              client: publicClient,
            ).getById(second.id);
            expect(publicDetails, isNull);

            final resubmitted = await ownerRepo.update(
              details!.copyWith(title: '$searchToken resubmitted property'),
            );
            expect(resubmitted.status, ListingStatus.pending);
            final noLongerPublic = await SupabaseListingsRepository(
              client: publicClient,
            ).getById(first.id);
            expect(noLongerPublic, isNull);
          } finally {
            await _cleanupTrackedResources(
              landlordClient: landlord,
              adminClient: admin,
            );
          }
        },
      );

      test(
        'Storage uploads persist scoped paths and deny another owner',
        () async {
          final ownerId = landlord!.auth.currentUser!.id;
          final category = await landlord!
              .from('categories')
              .select('name')
              .eq('is_active', true)
              .order('sort_order')
              .limit(1)
              .single();
          final area = await landlord!
              .from('areas')
              .select('name')
              .eq('is_active', true)
              .order('sort_order')
              .limit(1)
              .single();
          final ownerRepo = SupabaseListingsRepository(client: landlord!);
          final adminRepo = SupabaseListingsRepository(client: admin!);
          final publicClient = _newClient();
          addTearDown(publicClient.dispose);
          final titleMarker =
              'hostedstorage${DateTime.now().toUtc().microsecondsSinceEpoch}';
          final uploader = SupabaseMediaUploader(client: landlord!);
          var storagePath = '';

          try {
            final listingId = _newUuid();
            final existing = await admin!
                .from('listings')
                .select('id')
                .eq('id', listingId)
                .maybeSingle();
            if (existing != null) {
              throw StateError(
                'Generated listing ID already exists; refusing to reuse it.',
              );
            }
            final listing = await ownerRepo.create(
              _testListing(
                id: listingId,
                ownerId: ownerId,
                category: category['name'] as String,
                area: area['name'] as String,
                title: '$titleMarker test listing',
              ),
              onCreated: (id) => _trackListing(
                id: id,
                ownerId: ownerId,
                titleMarker: titleMarker,
              ),
            );
            const pngBytes = <int>[
              137,
              80,
              78,
              71,
              13,
              10,
              26,
              10,
              0,
              0,
              0,
              13,
              73,
              72,
              68,
              82,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              1,
              8,
              6,
              0,
              0,
              0,
              31,
              21,
              196,
              137,
              0,
              0,
              0,
              13,
              73,
              68,
              65,
              84,
              8,
              215,
              99,
              248,
              207,
              192,
              240,
              31,
              0,
              5,
              0,
              1,
              255,
              137,
              153,
              61,
              29,
              0,
              0,
              0,
              0,
              73,
              69,
              78,
              68,
              174,
              66,
              96,
              130,
            ];

            final secondOwnerId = secondLandlord!.auth.currentUser!.id;
            final foreignListingId = _newUuid();
            final foreignListingAlreadyExists = await admin!
                .from('listings')
                .select('id')
                .eq('id', foreignListingId)
                .maybeSingle();
            if (foreignListingAlreadyExists != null) {
              throw StateError(
                'Generated foreign listing ID already exists; refusing to '
                'reuse it.',
              );
            }
            final foreignListingMarker = '${titleMarker}foreign';
            final foreignListing =
                await SupabaseListingsRepository(client: secondLandlord!)
                    .create(
                      _testListing(
                        id: foreignListingId,
                        ownerId: secondOwnerId,
                        category: category['name'] as String,
                        area: area['name'] as String,
                        title: '$foreignListingMarker test listing',
                      ),
                      onCreated: (id) => _trackListing(
                        id: id,
                        ownerId: secondOwnerId,
                        titleMarker: foreignListingMarker,
                      ),
                    );
            final foreignListingPath =
                '$ownerId/${foreignListing.id}/'
                '${DateTime.now().toUtc().microsecondsSinceEpoch}_foreign.png';
            _trackStoragePath(foreignListingPath);
            Object? foreignPathError;
            try {
              await landlord!.storage
                  .from('listing-images')
                  .uploadBinary(
                    foreignListingPath,
                    Uint8List.fromList(pngBytes),
                    fileOptions: const FileOptions(contentType: 'image/png'),
                  );
            } catch (error) {
              foreignPathError = error;
            }
            final foreignPathObjects = await landlord!.storage
                .from('listing-images')
                .list(path: '$ownerId/${foreignListing.id}');
            if (foreignPathObjects.any(
              (object) => object.name == foreignListingPath.split('/').last,
            )) {
              throw StateError(
                'CRITICAL RLS FAILURE: a landlord uploaded an image to '
                'another owner’s listing path. The exact test object was '
                'tracked for cleanup.',
              );
            }
            if (foreignPathError == null ||
                !isStorageAuthorizationDenied(foreignPathError)) {
              throw StateError(
                'The foreign-listing image upload was not explicitly denied: '
                '$foreignPathError',
              );
            }

            final uploaded = await uploader.uploadPickedImages(
              [
                PickedMediaFile(
                  name: 'hosted-test.png',
                  bytes: Uint8List.fromList(pngBytes),
                  mimeType: 'image/png',
                ),
              ],
              listingId: listing.id,
              onUploadStarted: (_, path) {
                storagePath = path;
                _trackStoragePath(path);
              },
            );
            expect(storagePath, uploaded.single.storagePath);
            expect(storagePath, startsWith('$ownerId/${listing.id}/'));

            await ownerRepo.update(
              listing.copyWith(
                imageUrls: [''],
                imageStoragePaths: [storagePath],
                thumbnailUrl: '',
              ),
            );
            final loaded = await ownerRepo.getById(listing.id);
            expect(loaded?.imageStoragePaths, [storagePath]);
            expect(loaded?.imageUrls.single, contains('token='));

            final originalBytes = await landlord!.storage
                .from('listing-images')
                .download(storagePath);
            expect(originalBytes.toList(), pngBytes);

            final otherOwnerBucket = secondLandlord!.storage.from(
              'listing-images',
            );
            Future<List<int>> readOriginalPath() async =>
                (await landlord!.storage
                        .from('listing-images')
                        .download(storagePath))
                    .toList();
            Future<void> restoreOriginalObject() async {
              await landlord!.storage
                  .from('listing-images')
                  .uploadBinary(
                    storagePath,
                    Uint8List.fromList(pngBytes),
                    fileOptions: const FileOptions(
                      upsert: true,
                      contentType: 'image/png',
                    ),
                  );
            }

            final overwriteBytes = pngBytes
                .map((byte) => byte ^ 0xff)
                .toList(growable: false);
            await verifyStorageMutationWasDenied(
              operationName: 'Cross-owner Storage overwrite',
              originalBytes: pngBytes,
              attemptOperation: () => otherOwnerBucket.uploadBinary(
                storagePath,
                Uint8List.fromList(overwriteBytes),
                fileOptions: const FileOptions(
                  upsert: true,
                  contentType: 'image/png',
                ),
              ),
              readBytes: readOriginalPath,
              restoreOriginalBytes: restoreOriginalObject,
            );
            await verifyStorageMutationWasDenied(
              operationName: 'Cross-owner Storage delete',
              originalBytes: pngBytes,
              attemptOperation: () => otherOwnerBucket.remove([storagePath]),
              readBytes: readOriginalPath,
              restoreOriginalBytes: restoreOriginalObject,
              isNoopDenialResponse: (result) =>
                  result is List && result.isEmpty,
            );
            await adminRepo.setStatus(listing.id, ListingStatus.approved);
            final publicListing = await SupabaseListingsRepository(
              client: publicClient,
            ).getById(listing.id);
            expect(publicListing?.imageUrls.single, contains('token='));
            expect(publicListing?.imageStoragePaths, [storagePath]);
          } finally {
            await _cleanupTrackedResources(
              landlordClient: landlord,
              adminClient: admin,
            );
          }
        },
      );
    },
  );
}
