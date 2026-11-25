import 'dart:convert';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:arua_rentals/features/listings/data/supabase_listings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '5f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _listingId = '310ac401-4357-414e-834f-269edb122111';
const _categoryId = '211ac401-4357-414e-834f-269edb122111';
const _areaId = '411ac401-4357-414e-834f-269edb122111';
const _email = 'tenant@example.com';
const _accessToken = 'eyJhbGciOiJub25lIn0.eyJleHAiOjQ3MDAwMDAwMDB9.';

Map<String, dynamic> _listingRow() => {
  'id': _listingId,
  'owner_id': _userId,
  'owner_name': 'Arua Landlord',
  'owner_phone': '+256701234567',
  'type': 'property',
  'category_id': _categoryId,
  'categories': {'name': 'Rentals'},
  'area_id': _areaId,
  'areas': {'name': 'Oli'},
  'title': 'Room near the market',
  'title_lower': 'room near the market',
  'description': 'A clean room in central Arua.',
  'price_ugx': 350000,
  'price_unit': 'month',
  'address': 'Oli',
  'latitude': 3.02,
  'longitude': 30.91,
  'bedrooms': 1,
  'bathrooms': 1,
  'amenities': ['Water'],
  'thumbnail_url': 'https://images.example.test/room.jpg',
  'video_url': null,
  'status': 'approved',
  'rejection_reason': null,
  'rating_avg': 4.5,
  'rating_count': 2,
  'search_prefixes': ['room', 'oli'],
  'is_featured': false,
  'owner_verified': false,
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-01T00:00:00.000Z',
  'listing_images': [
    {
      'image_url': 'https://images.example.test/room.jpg',
      'storage_path': null,
      'display_order': 0,
    },
  ],
};

http.Response _jsonResponse(
  http.Request request,
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  request: request,
  headers: {'content-type': 'application/json', ...headers},
);

http.Response _emptyResponse(http.Request request, {int status = 204}) =>
    http.Response('', status, request: request);

Future<void> _signIn(SupabaseClient client) async {
  await client.auth.signInWithPassword(
    email: _email,
    password: 'valid-test-password',
  );
}

void main() {
  test(
    'maps Postgres listing fields and related tables into the app model',
    () {
      final listing = Listing.fromSupabaseRow(_listingRow());

      expect(listing.id, _listingId);
      expect(listing.ownerId, _userId);
      expect(listing.category, 'Rentals');
      expect(listing.area, 'Oli');
      expect(listing.priceUgx, 350000);
      expect(listing.imageUrls, ['https://images.example.test/room.jpg']);
      expect(listing.geo?.latitude, 3.02);
      expect(listing.createdAt?.toUtc(), DateTime.utc(2026));
      expect(listing.ratingCount, 2);
    },
  );

  test(
    'public browse sends approved filters and maps the Supabase row',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/rest/v1/categories')) {
            return _jsonResponse(request, [
              {'id': _categoryId},
            ]);
          }
          if (request.url.path.endsWith('/rest/v1/areas')) {
            return _jsonResponse(request, [
              {'id': _areaId},
            ]);
          }
          return _jsonResponse(
            request,
            [_listingRow()],
            headers: const {'content-range': '0-0/1'},
          );
        }),
      );
      addTearDown(client.dispose);

      final repository = SupabaseListingsRepository(client: client);
      final page = await repository.getApprovedListings(
        category: 'Rentals',
        area: 'Oli',
        keyword: 'room',
        limit: 1,
      );

      expect(page.items.single.title, 'Room near the market');
      expect(page.nextCursor, isNotNull);
      final request = requests.singleWhere(
        (request) => request.url.path.endsWith('/rest/v1/listings'),
      );
      expect(request.url.path, '/rest/v1/listings');
      expect(request.url.queryParameters['status'], 'eq.approved');
      expect(request.url.queryParameters['category_id'], 'eq.$_categoryId');
      expect(request.url.queryParameters['area_id'], 'eq.$_areaId');
      expect(request.url.queryParameters['search_prefixes'], 'cs.{"room"}');
      expect(
        request.url.queryParameters['order'],
        'created_at.desc.nullslast,id.desc.nullslast',
      );
      expect(request.url.queryParameters['limit'], '1');

      await repository.getApprovedListings(
        limit: 1,
        startAfter: ListingCursor(
          id: _listingId,
          createdAt: DateTime.utc(2026),
          priceUgx: 350000,
        ),
      );
      final nextPageRequest = requests.last;
      expect(
        nextPageRequest.url.queryParameters['or'],
        contains('created_at.lt.2026-01-01T00:00:00.000Z'),
      );
      expect(
        nextPageRequest.url.queryParameters['or'],
        contains('id.lt.$_listingId'),
      );
    },
  );

  test('featured listings are restricted to approved featured rows', () async {
    final requests = <http.Request>[];
    final featured = _listingRow()..['is_featured'] = true;
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/rest/v1/listings')) {
          return _jsonResponse(request, [featured]);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final listings = await SupabaseListingsRepository(client: client)
        .getFeaturedListings();

    expect(listings, hasLength(1));
    expect(listings.single.id, _listingId);
    expect(requests.single.url.queryParameters['status'], 'eq.approved');
    expect(requests.single.url.queryParameters['is_featured'], 'eq.true');
  });

  test('refreshes private Storage URLs when loading listing images', () async {
    final imagePath = '$_userId/$_listingId/room.jpg';
    final row = _listingRow()
      ..['thumbnail_url'] = 'https://expired.example.test/room.jpg'
      ..['listing_images'] = [
        {'image_url': null, 'storage_path': imagePath, 'display_order': 0},
      ];
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/rest/v1/listings')) {
          return _jsonResponse(request, row);
        }
        if (request.url.path.endsWith(
          '/storage/v1/object/sign/listing-images',
        )) {
          return _jsonResponse(request, [
            {
              'path': imagePath,
              'signedURL':
                  '/object/sign/listing-images/$imagePath?token=short-lived',
            },
          ]);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final listing = await SupabaseListingsRepository(client: client)
        .getById(_listingId);

    expect(listing, isNotNull);
    expect(listing!.imageStoragePaths, [imagePath]);
    expect(
      listing.imageUrls.single,
      contains('/object/sign/listing-images/$imagePath'),
    );
    expect(
      listing.thumbnailUrl,
      contains('/object/sign/listing-images/$imagePath'),
    );
    final signedRequest = requests.singleWhere(
      (request) =>
          request.url.path.endsWith('/storage/v1/object/sign/listing-images'),
    );
    expect(jsonDecode(signedRequest.body), containsPair('expiresIn', 3600));
  });

  test('refreshes pending listing images for an administrator', () async {
    const listingOwnerId = '7f6563bf-1b9f-45bf-94a4-a19161d3810a';
    final imagePath = '$listingOwnerId/$_listingId/room.jpg';
    final row = _listingRow()
      ..['owner_id'] = listingOwnerId
      ..['status'] = 'pending'
      ..['listing_images'] = [
        {'image_url': null, 'storage_path': imagePath, 'display_order': 0},
      ];
    var signedUrlRequestCount = 0;
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'admin@example.test',
              'app_metadata': {'admin': true},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (request.url.path.endsWith('/rest/v1/listings')) {
          return _jsonResponse(request, row);
        }
        if (request.url.path.endsWith(
          '/storage/v1/object/sign/listing-images',
        )) {
          signedUrlRequestCount++;
          return _jsonResponse(request, [
            {
              'path': imagePath,
              'signedURL':
                  '/object/sign/listing-images/$imagePath?token=admin-test',
            },
          ]);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await client.auth.signInWithPassword(
      email: 'admin@example.test',
      password: 'valid-test-password',
    );

    final listing = await SupabaseListingsRepository(client: client)
        .getById(_listingId);

    expect(listing, isNotNull);
    expect(listing!.status, ListingStatus.pending);
    expect(listing.imageUrls.single, contains('token=admin-test'));
    expect(signedUrlRequestCount, 1);
  });

  test(
    'persists image metadata before any signed URL refresh is requested',
    () async {
      final imagePath = '$_userId/$_listingId/new-room.jpg';
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/auth/v1/token')) {
            return _jsonResponse(request, {
              'access_token': _accessToken,
              'refresh_token': 'test-refresh-token',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': _userId,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': _email,
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2026-01-01T00:00:00.000Z',
              },
            });
          }
          if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
            return _jsonResponse(request, _listingRow());
          }
          if (path.endsWith('/rest/v1/categories')) {
            return _jsonResponse(request, [
              {'id': _categoryId},
            ]);
          }
          if (path.endsWith('/rest/v1/areas')) {
            return _jsonResponse(request, [
              {'id': _areaId},
            ]);
          }
          if (path.endsWith('/rest/v1/rpc/update_listing_with_images')) {
            return _emptyResponse(request);
          }
          return _jsonResponse(request, {
            'message': 'Unexpected request',
          }, status: 404);
        }),
      );
      addTearDown(client.dispose);
      await _signIn(client);

      final listing = Listing.fromSupabaseRow(_listingRow()).copyWith(
        imageUrls: const [''],
        imageStoragePaths: [imagePath],
        thumbnailUrl: '',
      );
      await SupabaseListingsRepository(client: client).update(listing);

      final listingUpdate = requests.singleWhere(
        (request) => request.url.path.endsWith(
          '/rest/v1/rpc/update_listing_with_images',
        ),
      );
      final rpcBody = jsonDecode(listingUpdate.body) as Map<String, dynamic>;
      expect(rpcBody['p_listing_id'], _listingId);
      expect(rpcBody['p_listing_data'], isA<Map<String, dynamic>>());
      final imageRow =
          (rpcBody['p_images'] as List).single as Map<String, dynamic>;
      expect(imageRow['storage_path'], imagePath);
      expect(imageRow['image_url'], isNull);
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/rest/v1/listings') &&
              request.method == 'PATCH',
        ),
        isFalse,
      );
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/rest/v1/rpc/replace_listing_images'),
        ),
        isFalse,
      );
      expect(
        requests.any(
          (request) => request.url.path.contains('/storage/v1/object/sign/'),
        ),
        isFalse,
      );
    },
  );

  test('listing and image update fail through one atomic RPC call', () async {
    final mutationRequests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
          return _jsonResponse(request, _listingRow());
        }
        if (path.endsWith('/rest/v1/categories')) {
          return _jsonResponse(request, [
            {'id': _categoryId},
          ]);
        }
        if (path.endsWith('/rest/v1/areas')) {
          return _jsonResponse(request, [
            {'id': _areaId},
          ]);
        }
        if (path.endsWith('/rest/v1/rpc/update_listing_with_images')) {
          mutationRequests.add(request);
          return _jsonResponse(request, {
            'message': 'Simulated atomic listing/image update failure',
            'code': '23514',
          }, status: 400);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);

    await expectLater(
      SupabaseListingsRepository(client: client).update(
        Listing.fromSupabaseRow(_listingRow()).copyWith(
          title: 'Updated title',
          imageUrls: const ['https://images.example.test/new-room.jpg'],
          imageStoragePaths: const [null],
        ),
      ),
      throwsA(isA<AppException>()),
    );

    expect(mutationRequests, hasLength(1));
  });

  test('landlord creation skips empty image metadata and preserves protected fields', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (path.endsWith('/rest/v1/profiles')) {
          return _jsonResponse(request, {
            'full_name': 'Arua Landlord',
            'phone': '+256701234567',
            'role': 'landlord',
            'is_verified': false,
          });
        }
        if (path.endsWith('/rest/v1/categories')) {
          return _jsonResponse(request, [
            {'id': _categoryId},
          ]);
        }
        if (path.endsWith('/rest/v1/areas')) {
          return _jsonResponse(request, [
            {'id': _areaId},
          ]);
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'POST') {
          return _jsonResponse(request, {'id': _listingId}, status: 201);
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
          return _jsonResponse(
            request,
            _listingRow()..['listing_images'] = <Map<String, dynamic>>[],
          );
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);

    final listing = Listing(
      id: '',
      ownerId: 'untrusted-client-owner',
      ownerName: 'Untrusted client name',
      ownerPhone: '+256700000000',
      type: ListingType.property,
      category: 'Rentals',
      title: 'Room near the market',
      description: 'A clean room in central Arua.',
      priceUgx: 350000,
      priceUnit: ListingPriceUnit.month,
      area: 'Oli',
      amenities: const [],
      imageUrls: const [],
      imageStoragePaths: const [],
      thumbnailUrl: '',
      searchKeywords: const [],
      status: ListingStatus.approved,
      ratingAvg: 5,
      ratingCount: 999,
      isFeatured: true,
      ownerVerified: true,
    );

    final created = await SupabaseListingsRepository(client: client)
        .create(listing);

    expect(created.id, _listingId);
    final insert = requests.singleWhere(
      (request) =>
          request.url.path.endsWith('/rest/v1/listings') &&
          request.method == 'POST',
    );
    final body = jsonDecode(insert.body) as Map<String, dynamic>;
    expect(body['owner_id'], _userId);
    expect(body['owner_name'], 'Arua Landlord');
    expect(body['owner_phone'], '+256701234567');
    expect(body['status'], 'pending');
    expect(body['thumbnail_url'], isNull);
    expect(body, isNot(contains('rating_avg')));
    expect(body, isNot(contains('rating_count')));
    expect(body, isNot(contains('is_featured')));
    expect(body, isNot(contains('owner_verified')));
    expect(
      requests.any(
        (request) =>
            request.url.path.endsWith('/rest/v1/rpc/replace_listing_images'),
      ),
      isFalse,
    );
  });

  test('tracks created listing before image persistence can fail', () async {
    var callbackListingId = '';
    var callbackObservedBeforeImagePersistence = false;
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (path.endsWith('/rest/v1/profiles')) {
          return _jsonResponse(request, {
            'full_name': 'Arua Landlord',
            'phone': '+256701234567',
            'role': 'landlord',
            'is_verified': false,
          });
        }
        if (path.endsWith('/rest/v1/categories')) {
          return _jsonResponse(request, [
            {'id': _categoryId},
          ]);
        }
        if (path.endsWith('/rest/v1/areas')) {
          return _jsonResponse(request, [
            {'id': _areaId},
          ]);
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'POST') {
          return _jsonResponse(request, {'id': _listingId}, status: 201);
        }
        if (path.endsWith('/rest/v1/rpc/replace_listing_images')) {
          callbackObservedBeforeImagePersistence =
              callbackListingId == _listingId;
          return _jsonResponse(request, {
            'message': 'Simulated image metadata failure',
            'code': '23514',
          }, status: 400);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);

    final listing = Listing(
      id: _listingId,
      ownerId: _userId,
      ownerName: 'Arua Landlord',
      ownerPhone: '+256701234567',
      type: ListingType.property,
      category: 'Rentals',
      title: 'Hosted callback test',
      description: 'Callback must run before image persistence.',
      priceUgx: 350000,
      priceUnit: ListingPriceUnit.month,
      area: 'Oli',
      amenities: const [],
      imageUrls: const ['https://images.example.test/test.png'],
      thumbnailUrl: 'https://images.example.test/test.png',
      searchKeywords: const [],
      status: ListingStatus.pending,
      ratingAvg: 0,
      ratingCount: 0,
      isFeatured: false,
    );

    await expectLater(
      SupabaseListingsRepository(client: client)
          .create(listing, onCreated: (id) => callbackListingId = id),
      throwsA(isA<AppException>()),
    );
    expect(callbackListingId, _listingId);
    expect(callbackObservedBeforeImagePersistence, isTrue);
  });

  test('tenant role cannot create listings', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (request.url.path.endsWith('/rest/v1/profiles')) {
          return _jsonResponse(request, {
            'full_name': 'Arua Tenant',
            'phone': '+256701234567',
            'role': 'tenant',
            'is_verified': false,
          });
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = SupabaseListingsRepository(client: client);

    await expectLater(
      repository.create(
        Listing(
          id: '',
          ownerId: '',
          ownerName: '',
          ownerPhone: '',
          type: ListingType.property,
          category: 'Rentals',
          title: 'Room',
          description: 'A room.',
          priceUgx: 350000,
          priceUnit: ListingPriceUnit.month,
          area: 'Oli',
          amenities: const [],
          imageUrls: const [],
          thumbnailUrl: '',
          searchKeywords: const [],
          status: ListingStatus.pending,
          ratingAvg: 0,
          ratingCount: 0,
          isFeatured: false,
        ),
      ),
      throwsA(isA<AppException>()),
    );
    expect(
      requests.any(
        (request) =>
            request.url.path.endsWith('/rest/v1/listings') &&
            request.method == 'POST',
      ),
      isFalse,
    );
  });

  test('refreshes private Storage URLs when loading listing video', () async {
    final videoPath = '$_userId/$_listingId/tour.mp4';
    final row = _listingRow()
      ..['video_url'] = videoPath
      ..['listing_images'] = const <Map<String, dynamic>>[];
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/rest/v1/listings')) {
          return _jsonResponse(request, row);
        }
        if (request.url.path.endsWith(
          '/storage/v1/object/sign/listing-videos',
        )) {
          return _jsonResponse(request, [
            {
              'path': videoPath,
              'signedURL':
                  '/object/sign/listing-videos/$videoPath?token=short-lived',
            },
          ]);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final listing = await SupabaseListingsRepository(client: client)
        .getById(_listingId);

    expect(listing, isNotNull);
    expect(listing!.videoStoragePath, videoPath);
    expect(
      listing.videoUrl,
      contains('/object/sign/listing-videos/$videoPath'),
    );
    final signedRequest = requests.singleWhere(
      (request) =>
          request.url.path.endsWith('/storage/v1/object/sign/listing-videos'),
    );
    expect(jsonDecode(signedRequest.body), containsPair('expiresIn', 3600));
  });

  test('persists and clears video storage path through listing update RPC', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (path.endsWith('/rest/v1/profiles')) {
          return _jsonResponse(request, {
            'full_name': 'Arua Landlord',
            'phone': '+256701234567',
            'role': 'landlord',
            'is_verified': false,
          });
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
          return _jsonResponse(request, _listingRow());
        }
        if (path.endsWith('/rest/v1/categories')) {
          return _jsonResponse(request, [
            {'id': _categoryId},
          ]);
        }
        if (path.endsWith('/rest/v1/areas')) {
          return _jsonResponse(request, [
            {'id': _areaId},
          ]);
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'PATCH') {
          return _jsonResponse(request, {'id': _listingId});
        }
        if (path.endsWith('/rest/v1/rpc/update_listing_with_images')) {
          return _emptyResponse(request);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = SupabaseListingsRepository(client: client);

    final withVideo = Listing(
      id: _listingId,
      ownerId: _userId,
      ownerName: 'Arua Landlord',
      ownerPhone: '+256701234567',
      type: ListingType.property,
      category: 'Rentals',
      title: 'Self-contained room near campus',
      description: 'Video persistence test.',
      priceUgx: 350000,
      priceUnit: ListingPriceUnit.month,
      area: 'Oli',
      amenities: const ['Water'],
      imageUrls: const ['https://images.example.test/room.jpg'],
      imageStoragePaths: const [null],
      thumbnailUrl: 'https://images.example.test/room.jpg',
      videoUrl: '$_userId/$_listingId/tour.mp4',
      videoStoragePath: '$_userId/$_listingId/tour.mp4',
      searchKeywords: const [],
      status: ListingStatus.pending,
      ratingAvg: 0,
      ratingCount: 0,
      isFeatured: false,
    );
    await repository.update(withVideo);
    final persistRequest = requests.lastWhere(
      (request) =>
          request.url.path.endsWith('/rest/v1/listings') &&
          request.method == 'PATCH',
    );
    final persistBody = jsonDecode(persistRequest.body) as Map<String, dynamic>;
    expect(persistBody['video_url'], '$_userId/$_listingId/tour.mp4');

    final cleared = withVideo.copyWith(clearVideo: true);
    await repository.update(cleared);
    final clearRequest = requests.lastWhere(
      (request) =>
          request.url.path.endsWith('/rest/v1/listings') &&
          request.method == 'PATCH',
    );
    final clearBody = jsonDecode(clearRequest.body) as Map<String, dynamic>;
    expect(clearBody.containsKey('video_url'), isTrue);
    expect(clearBody['video_url'], isNull);
  });

  test(
    'updates a listing without image changes when update RPC is missing',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/auth/v1/token')) {
            return _jsonResponse(request, {
              'access_token': _accessToken,
              'refresh_token': 'test-refresh-token',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': _userId,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': _email,
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2026-01-01T00:00:00.000Z',
              },
            });
          }
          if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
            return _jsonResponse(request, _listingRow());
          }
          if (path.endsWith('/rest/v1/categories')) {
            return _jsonResponse(request, [
              {'id': _categoryId},
            ]);
          }
          if (path.endsWith('/rest/v1/areas')) {
            return _jsonResponse(request, [
              {'id': _areaId},
            ]);
          }
          if (path.endsWith('/rest/v1/listings') && request.method == 'PATCH') {
            return _jsonResponse(request, {'id': _listingId});
          }
          if (path.endsWith('/rest/v1/rpc/update_listing_with_images')) {
            return _jsonResponse(request, {
              'message': 'Could not find the function public.update_listing_with_images',
              'code': 'PGRST202',
            }, status: 404);
          }
          return _jsonResponse(request, {
            'message': 'Unexpected request ${request.method} $path',
          }, status: 404);
        }),
      );
      addTearDown(client.dispose);
      await _signIn(client);

      final listing = Listing.fromSupabaseRow(_listingRow()).copyWith(
        title: 'Updated without image change',
        description: 'Updated description',
        priceUgx: 400000,
      );
      await SupabaseListingsRepository(client: client).update(listing);

      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/rest/v1/rpc/update_listing_with_images'),
        ),
        isFalse,
      );
      final patch = requests.singleWhere(
        (request) =>
            request.url.path.endsWith('/rest/v1/listings') &&
            request.method == 'PATCH',
      );
      final body = jsonDecode(patch.body) as Map<String, dynamic>;
      expect(body['title'], 'Updated without image change');
      expect(body['description'], 'Updated description');
      expect(body['price_ugx'], 400000);
    },
  );

  test('owner cannot update another user listing', () async {
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, {
            'access_token': _accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': _userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': _email,
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00.000Z',
            },
          });
        }
        if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
          return _jsonResponse(request, {
            ..._listingRow(),
            'owner_id': '11111111-1111-4111-8111-111111111111',
          });
        }
        return _jsonResponse(request, {'message': 'Unexpected $path'}, status: 404);
      }),
    );
    addTearDown(client.dispose);
    await _signIn(client);

    await expectLater(
      SupabaseListingsRepository(client: client).update(
        Listing.fromSupabaseRow(_listingRow()).copyWith(title: 'Nope'),
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          contains('own listings'),
        ),
      ),
    );
  });

  test(
    'falls back to direct image replacement when update RPC is missing',
    () async {
      final requests = <http.Request>[];
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/auth/v1/token')) {
            return _jsonResponse(request, {
              'access_token': _accessToken,
              'refresh_token': 'test-refresh-token',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': _userId,
                'aud': 'authenticated',
                'role': 'authenticated',
                'email': _email,
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2026-01-01T00:00:00.000Z',
              },
            });
          }
          if (path.endsWith('/rest/v1/listings') && request.method == 'GET') {
            return _jsonResponse(request, _listingRow());
          }
          if (path.endsWith('/rest/v1/categories')) {
            return _jsonResponse(request, [{'id': _categoryId}]);
          }
          if (path.endsWith('/rest/v1/areas')) {
            return _jsonResponse(request, [{'id': _areaId}]);
          }
          if (path.endsWith('/rest/v1/rpc/update_listing_with_images')) {
            return _jsonResponse(request, {
              'message': 'Could not find the function public.update_listing_with_images',
              'code': 'PGRST202',
            }, status: 404);
          }
          if (path.endsWith('/rest/v1/listings') && request.method == 'PATCH') {
            return _jsonResponse(request, {'id': _listingId});
          }
          if (path.endsWith('/rest/v1/listing_images') && request.method == 'DELETE') {
            return _emptyResponse(request);
          }
          if (path.endsWith('/rest/v1/listing_images') && request.method == 'POST') {
            return _emptyResponse(request);
          }
          return _jsonResponse(request, {'message': 'Unexpected ${request.method} $path'}, status: 404);
        }),
      );
      addTearDown(client.dispose);
      await _signIn(client);

      final listing = Listing.fromSupabaseRow(_listingRow()).copyWith(
        title: 'Updated title',
        imageUrls: const ['https://images.example.test/new-room.jpg'],
        imageStoragePaths: const [null],
        thumbnailUrl: 'https://images.example.test/new-room.jpg',
      );
      await SupabaseListingsRepository(client: client).update(listing);

      expect(
        requests.any((r) => r.url.path.endsWith('/rest/v1/rpc/update_listing_with_images')),
        isTrue,
      );
      expect(
        requests.any((r) => r.url.path.endsWith('/rest/v1/listings') && r.method == 'PATCH'),
        isTrue,
      );
      expect(
        requests.any((r) => r.url.path.endsWith('/rest/v1/listing_images') && r.method == 'DELETE'),
        isTrue,
      );
      expect(
        requests.any((r) => r.url.path.endsWith('/rest/v1/listing_images') && r.method == 'POST'),
        isTrue,
      );
    },
  );
}

