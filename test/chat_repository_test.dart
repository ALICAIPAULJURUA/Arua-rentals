import 'dart:convert';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/chat/data/chat_repository.dart';
import 'package:arua_rentals/features/listings/data/listing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tenantId = '5f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _ownerId = '7f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _listingId = '310ac401-4357-414e-834f-269edb122111';
const _roomId = '410ac401-4357-414e-834f-269edb122111';
const _messageId = '510ac401-4357-414e-834f-269edb122111';
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
  test('opens rooms through the trusted RPC and rejects self-chat', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rpc/open_chat_room')) {
        return _jsonResponse(request, _roomId);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = ChatRepository(client: client);

    final roomId = await repository.openRoom(
      currentUid: _tenantId,
      listing: _listing(),
    );

    expect(roomId, _roomId);
    final request = requests.last;
    expect(jsonDecode(request.body), {'p_listing_id': _listingId});
    await expectLater(
      repository.openRoom(
        currentUid: _tenantId,
        listing: _listing(ownerId: _tenantId),
      ),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      repository.openRoom(currentUid: _ownerId, listing: _listing()),
      throwsA(isA<AppException>()),
    );
  });

  test('loads participant chat room and listing snapshot', () async {
    final client = _makeClient((request) async {
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rest/v1/chat_rooms')) {
        return _jsonResponse(request, [_roomRow()]);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    final room = await ChatRepository(client: client).getRoom(_roomId);

    expect(room.id, _roomId);
    expect(room.participants, [_tenantId, _ownerId]);
    expect(room.listingId, _listingId);
    expect(room.listingTitle, 'Room in Arua');
    expect(room.listingThumb, 'https://images.example.test/room.jpg');
    expect(room.lastMessage, 'Hello');
    expect(room.unreadFor(_tenantId), 0);
    expect(room.unreadFor(_ownerId), 1);
  });

  test('sends and marks messages only through authenticated RPCs', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rpc/send_chat_message')) {
        return _jsonResponse(request, _messageId);
      }
      if (request.url.path.endsWith('/rpc/mark_chat_read')) {
        return http.Response('', 204, request: request);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = ChatRepository(client: client);

    await repository.sendMessage(
      roomId: _roomId,
      senderId: _tenantId,
      text: '  Hello  ',
    );
    await repository.markRead(_roomId, _tenantId);

    expect(requests[1].url.path, endsWith('/rpc/send_chat_message'));
    expect(jsonDecode(requests[1].body), {
      'p_room_id': _roomId,
      'p_message': 'Hello',
    });
    expect(requests[2].url.path, endsWith('/rpc/mark_chat_read'));
    expect(jsonDecode(requests[2].body), {'p_room_id': _roomId});
    await expectLater(
      repository.sendMessage(
        roomId: _roomId,
        senderId: _ownerId,
        text: 'Not this account',
      ),
      throwsA(isA<AppException>()),
    );
  });

  test('validates message size and maps participant denial', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      return _jsonResponse(request, {
        'code': 'P0001',
        'message': 'You cannot access this chat',
        'details': null,
        'hint': null,
      }, status: 400);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = ChatRepository(client: client);

    await expectLater(
      repository.sendMessage(roomId: _roomId, senderId: _tenantId, text: '  '),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      repository.sendMessage(
        roomId: _roomId,
        senderId: _tenantId,
        text: List.filled(1001, 'x').join(),
      ),
      throwsA(isA<AppException>()),
    );
    expect(requests, hasLength(1));
    await expectLater(
      repository.sendMessage(
        roomId: _roomId,
        senderId: _tenantId,
        text: 'Hello',
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          'You cannot access this chat',
        ),
      ),
    );
  });

  test('loads older messages with a stable timestamp and id cursor', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _jsonResponse(request, _authResponse());
      }
      if (request.url.path.endsWith('/rest/v1/chat_messages')) {
        return _jsonResponse(request, [_messageRow()]);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    final page = await ChatRepository(client: client).getOlderMessages(
      _roomId,
      startAfter: ChatCursor(
        createdAt: DateTime.parse('2026-01-02T03:04:05.000Z'),
        id: _messageId,
      ),
      limit: 1,
    );

    expect(page.items.single.text, 'Earlier');
    expect(page.nextCursor, isNotNull);
    expect(requests.last.url.queryParameters['room_id'], 'eq.$_roomId');
    expect(requests.last.url.queryParameters['or'], contains(_messageId));
  });
}

Map<String, dynamic> _authResponse() => {
  'access_token': _accessToken,
  'refresh_token': 'test-refresh-token',
  'expires_in': 3600,
  'token_type': 'bearer',
  'user': {
    'id': _tenantId,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'tenant@example.test',
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
    'created_at': '2026-01-01T00:00:00.000Z',
  },
};

Map<String, dynamic> _roomRow() => {
  'id': _roomId,
  'listing_id': _listingId,
  'participant_one': _tenantId,
  'participant_two': _ownerId,
  'last_message': 'Hello',
  'last_message_at': '2026-01-02T03:04:05.000Z',
  'unread_count': {_tenantId: 0, _ownerId: 1},
  'created_at': '2026-01-01T00:00:00.000Z',
  'listings': {
    'title': 'Room in Arua',
    'thumbnail_url': 'https://images.example.test/room.jpg',
  },
};

Map<String, dynamic> _messageRow() => {
  'id': _messageId,
  'sender_id': _ownerId,
  'message': 'Earlier',
  'created_at': '2026-01-01T03:04:05.000Z',
};

Listing _listing({String ownerId = _ownerId}) => Listing(
  id: _listingId,
  ownerId: ownerId,
  ownerName: 'Arua Owner',
  ownerPhone: '+256700111222',
  type: ListingType.property,
  category: 'Rentals',
  title: 'Room in Arua',
  description: 'A test listing.',
  priceUgx: 350000,
  priceUnit: ListingPriceUnit.month,
  area: 'Oli',
  amenities: const [],
  imageUrls: const [],
  thumbnailUrl: 'https://images.example.test/room.jpg',
  searchKeywords: const [],
  status: ListingStatus.approved,
  ratingAvg: 0,
  ratingCount: 0,
  isFeatured: false,
);
