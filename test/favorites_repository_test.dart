import 'dart:convert';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/favorites/data/favorites_repository.dart';
import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '5f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _listingId = '310ac401-4357-414e-834f-269edb122111';
const _accessToken = 'eyJhbGciOiJub25lIn0.eyJleHAiOjQ3MDAwMDAwMDB9.';

http.Response _jsonResponse(
  http.Request request,
  Object body, {
  int status = 200,
}) => http.Response(
  jsonEncode(body),
  status,
  request: request,
  headers: const {'content-type': 'application/json'},
);

Map<String, dynamic> _listingRow({String? imagePath}) => {
  'id': _listingId,
  'owner_id': 'owner-id',
  'owner_name': 'Arua Landlord',
  'owner_phone': '+256701234567',
  'type': 'property',
  'category_id': '211ac401-4357-414e-834f-269edb122111',
  'categories': {'name': 'Rentals'},
  'area_id': '411ac401-4357-414e-834f-269edb122111',
  'areas': {'name': 'Oli'},
  'title': 'Room near the market',
  'title_lower': 'room near the market',
  'description': 'A clean room in central Arua.',
  'price_ugx': 350000,
  'price_unit': 'month',
  'address': 'Oli',
  'latitude': null,
  'longitude': null,
  'bedrooms': 1,
  'bathrooms': 1,
  'amenities': ['Water'],
  'thumbnail_url': imagePath == null
      ? 'https://images.example.test/room.jpg'
      : null,
  'video_url': null,
  'status': 'approved',
  'rejection_reason': null,
  'rating_avg': 0,
  'rating_count': 0,
  'search_prefixes': ['room'],
  'is_featured': false,
  'owner_verified': false,
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-01T00:00:00.000Z',
  'listing_images': [
    {
      'image_url': imagePath == null
          ? 'https://images.example.test/room.jpg'
          : null,
      'storage_path': imagePath,
      'display_order': 0,
    },
  ],
};

Map<String, dynamic> _favoriteRow({
  String listingId = _listingId,
  Object? listing = const {},
  String createdAt = '2026-02-01T12:00:00.000Z',
}) => {
  'listing_id': listingId,
  'created_at': createdAt,
  'listings': listing == const {} ? _listingRow() : listing,
};

SupabaseClient _makeClient(
  Future<http.Response> Function(http.Request request) handler,
) => SupabaseClient(
  'https://test-project.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  httpClient: MockClient(handler),
);

Future<void> _signIn(SupabaseClient client) async {
  await client.auth.signInWithPassword(
    email: 'tenant@example.test',
    password: 'valid-test-password',
  );
}

void main() {
  test("reads a user's favorites and maps joined listing data", () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rest/v1/favorites')) {
        return _jsonResponse(request, [_favoriteRow()]);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    final page = await FavoritesRepository(client: client)
        .getPage(_userId, limit: 1);

    expect(page.items, hasLength(1));
    expect(page.items.single.listingId, _listingId);
    expect(page.items.single.title, 'Room near the market');
    expect(page.items.single.priceUgx, 350000);
    expect(page.items.single.area, 'Oli');
    expect(page.items.single.isAvailable, isTrue);
    expect(page.nextCursor, isNotNull);
    expect(requests.last.url.queryParameters['user_id'], 'eq.$_userId');
  });

  test(
    'preserves favorite pagination cursor and returns unavailable rows',
    () async {
      final favoriteRequests = <http.Request>[];
      final client = _makeClient((request) async {
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _jsonResponse(request, _authResponse());
        }
        if (request.url.path.endsWith('/rest/v1/favorites')) {
          favoriteRequests.add(request);
          if (favoriteRequests.length == 1) {
            return _jsonResponse(request, [_favoriteRow(listing: null)]);
          }
          return _jsonResponse(request, <Object>[]);
        }
        return _jsonResponse(request, {
          'message': 'Unexpected request',
        }, status: 404);
      });
      addTearDown(client.dispose);
      await _signIn(client);

      final repository = FavoritesRepository(client: client);
      final first = await repository.getPage(_userId, limit: 1);
      final second = await repository.getPage(
        _userId,
        limit: 1,
        startAfter: first.nextCursor,
      );

      expect(first.items.single.isAvailable, isFalse);
      expect(first.items.single.title, 'Listing unavailable');
      expect(first.nextCursor, isNotNull);
      expect(second.items, isEmpty);
      expect(second.nextCursor, isNull);
      expect(favoriteRequests.last.url.queryParameters, contains('or'));
    },
  );

  test('upserts and removes only the authenticated user favorite', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rest/v1/favorites')) {
        return http.Response('', 204, request: request);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = FavoritesRepository(client: client);

    await repository.setSaved(_userId, _listing(), saved: true);
    await repository.setSaved(_userId, _listing(), saved: false);

    final upsert = requests.firstWhere(
      (request) =>
          request.url.path.endsWith('/rest/v1/favorites') &&
          request.method == 'POST',
    );
    expect(upsert.url.queryParameters['on_conflict'], 'user_id,listing_id');
    expect(jsonDecode(upsert.body), {
      'user_id': _userId,
      'listing_id': _listingId,
    });
    final remove = requests.last;
    expect(remove.method, 'DELETE');
    expect(remove.url.queryParameters['user_id'], 'eq.$_userId');
    expect(remove.url.queryParameters['listing_id'], 'eq.$_listingId');

    await expectLater(
      repository.isSaved('another-user', _listingId),
      throwsA(isA<AppException>()),
    );
  });

  test('signs Storage-backed image paths before mapping favorites', () async {
    final client = _makeClient((request) async {
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rest/v1/favorites')) {
        return _jsonResponse(request, [
          _favoriteRow(
            listing: _listingRow(imagePath: '$_userId/$_listingId/room.png'),
          ),
        ]);
      }
      if (request.url.path.contains('/storage/v1/object/sign/')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final path = (body['paths'] as List).single as String;
        return _jsonResponse(request, [
          {
            'path': path,
            'signedURL': '/object/sign/listing-images/$path?token=test',
          },
        ]);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    final page = await FavoritesRepository(client: client).getPage(_userId);

    expect(
      page.items.single.thumbnailUrl,
      contains('/object/sign/listing-images/'),
    );
  });

  test('rejects page sizes outside the bounded range', () async {
    final client = _makeClient((request) async {
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      return _jsonResponse(request, <Object>[]);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    await expectLater(
      FavoritesRepository(client: client).getPage(_userId, limit: 101),
      throwsA(isA<AppException>()),
    );
  });
}

Map<String, dynamic> _authResponse() => {
  'access_token': _accessToken,
  'refresh_token': 'test-refresh-token',
  'expires_in': 3600,
  'token_type': 'bearer',
  'user': {
    'id': _userId,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'tenant@example.test',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
    'created_at': '2026-01-01T00:00:00.000Z',
  },
};

Listing _listing() => Listing(
  id: _listingId,
  ownerId: 'owner-id',
  ownerName: 'Owner',
  ownerPhone: '+256700111222',
  type: ListingType.property,
  category: 'Rentals',
  title: 'Arua room',
  description: 'A test listing.',
  priceUgx: 350000,
  priceUnit: ListingPriceUnit.month,
  area: 'Oli',
  amenities: const [],
  imageUrls: const [],
  thumbnailUrl: 'https://example.test/room.jpg',
  searchKeywords: const [],
  status: ListingStatus.approved,
  ratingAvg: 0,
  ratingCount: 0,
  isFeatured: false,
);
