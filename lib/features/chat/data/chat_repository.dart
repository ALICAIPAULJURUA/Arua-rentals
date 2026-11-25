import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../listings/data/listing.dart';

class ChatCursor {
  const ChatCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;
}

class ChatRoom {
  const ChatRoom({
    required this.id,
    required this.participants,
    required this.listingId,
    required this.listingTitle,
    required this.listingThumb,
    required this.lastMessage,
    required this.lastMessageAt,
    required this.unreadCount,
    required this.createdAt,
  });

  final String id;
  final List<String> participants;
  final String listingId;
  final String listingTitle;
  final String listingThumb;
  final String lastMessage;
  final DateTime lastMessageAt;
  final Map<String, int> unreadCount;
  final DateTime createdAt;

  int unreadFor(String uid) => unreadCount[uid] ?? 0;

  String otherParticipant(String uid) =>
      participants.firstWhere((participant) => participant != uid);
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime createdAt;
}

class ChatMessagePage {
  const ChatMessagePage({required this.items, required this.nextCursor});

  final List<ChatMessage> items;
  final ChatCursor? nextCursor;
}

class ChatRepository {
  static const pageSize = 30;
  static const _roomSelection = '''
    id, listing_id, participant_one, participant_two,
    last_message, last_message_at, unread_count, created_at
  ''';
  static const _messageSelection = 'id, sender_id, message, created_at';
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  ChatRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<String> openRoom({
    required String currentUid,
    required Listing listing,
  }) async {
    _requireUser(currentUid);
    _requireUuid(listing.id, 'listing');
    if (currentUid == listing.ownerId) {
      throw const AppException('You cannot chat with yourself.');
    }
    try {
      final result = await _client.rpc(
        'open_chat_room',
        params: {'p_listing_id': listing.id},
      );
      if (result is! String || !_uuidPattern.hasMatch(result)) {
        throw const AppException('The chat room could not be opened.');
      }
      return result;
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'open this chat');
    }
  }

  Future<ChatRoom> getRoom(String roomId) async {
    _requireUser();
    _requireUuid(roomId, 'chat');
    try {
      final row = await _client
          .from('chat_rooms')
          .select('$_roomSelection, listings(title, thumbnail_url)')
          .eq('id', roomId)
          .maybeSingle();
      if (row == null) {
        throw const AppException('This chat no longer exists.');
      }
      return _roomFromRow(row);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load this chat');
    }
  }

  Stream<List<ChatRoom>> watchRooms(String uid) {
    _requireUser(uid);
    return _client
        .from('chat_rooms')
        .stream(primaryKey: const ['id'])
        .order('last_message_at', ascending: false)
        .limit(50)
        .asyncMap((rows) async {
          final ownRows = rows.where(
            (row) =>
                row['participant_one'] == uid || row['participant_two'] == uid,
          );
          final listingDetails = await _loadListingDetails(ownRows.toList());
          return ownRows
              .map((row) => _roomFromRow(row, listingDetails: listingDetails))
              .toList(growable: false);
        });
  }

  Stream<ChatMessagePage> watchRecentMessages(
    String roomId, {
    int limit = pageSize,
  }) {
    _requireUser();
    _requireUuid(roomId, 'chat');
    _requirePageLimit(limit);
    return _client
        .from('chat_messages')
        .stream(primaryKey: const ['id'])
        .eq('room_id', roomId)
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit)
        .map((rows) => _messagePage(rows, limit));
  }

  Future<ChatMessagePage> getOlderMessages(
    String roomId, {
    required ChatCursor startAfter,
    int limit = pageSize,
  }) async {
    _requireUser();
    _requireUuid(roomId, 'chat');
    _requireUuid(startAfter.id, 'message');
    _requirePageLimit(limit);
    try {
      final timestamp = startAfter.createdAt.toUtc().toIso8601String();
      final rows = await _client
          .from('chat_messages')
          .select(_messageSelection)
          .eq('room_id', roomId)
          .or(
            'created_at.lt.$timestamp,'
            'and(created_at.eq.$timestamp,id.lt.${startAfter.id})',
          )
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit);
      return _messagePage(rows, limit);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load earlier messages');
    }
  }

  Future<void> markRead(String roomId, String uid) async {
    _requireUser(uid);
    _requireUuid(roomId, 'chat');
    try {
      await _client.rpc('mark_chat_read', params: {'p_room_id': roomId});
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'mark this chat as read');
    }
  }

  Future<void> sendMessage({
    required String roomId,
    required String senderId,
    required String text,
  }) async {
    _requireUser(senderId);
    _requireUuid(roomId, 'chat');
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 1000) {
      throw const AppException('Messages must be 1 to 1000 characters.');
    }
    try {
      await _client.rpc(
        'send_chat_message',
        params: {'p_room_id': roomId, 'p_message': normalized},
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'send this message');
    }
  }

  Future<Map<String, Map<String, dynamic>>> _loadListingDetails(
    List<Map<String, dynamic>> rows,
  ) async {
    final listingIds = rows
        .map((row) => row['listing_id'])
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    if (listingIds.isEmpty) return const {};
    try {
      final results = await _client
          .from('listings')
          .select('id, title, thumbnail_url')
          .inFilter('id', listingIds);
      return {
        for (final row in results)
          if (row['id'] is String) row['id'] as String: row,
      };
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load chat listing details');
    }
  }

  ChatRoom _roomFromRow(
    Map<String, dynamic> row, {
    Map<String, Map<String, dynamic>> listingDetails = const {},
  }) {
    final id = row['id'];
    final listingId = row['listing_id'];
    final first = row['participant_one'];
    final second = row['participant_two'];
    final lastMessage = row['last_message'];
    final lastMessageAt = _parseDate(row['last_message_at']);
    final createdAt = _parseDate(row['created_at']);
    final rawUnread = row['unread_count'];
    if (id is! String ||
        listingId is! String ||
        first is! String ||
        second is! String ||
        first == second ||
        lastMessage is! String ||
        lastMessageAt == null ||
        createdAt == null ||
        rawUnread is! Map) {
      throw const AppException('This chat contains invalid data.');
    }
    final unreadCount = <String, int>{};
    for (final entry in rawUnread.entries) {
      if (entry.key is! String ||
          entry.value is! num ||
          (entry.value as num) < 0) {
        throw const AppException('This chat contains invalid unread data.');
      }
      unreadCount[entry.key as String] = (entry.value as num).toInt();
    }
    final joinedListing = row['listings'];
    final listing = joinedListing is Map
        ? Map<String, dynamic>.from(joinedListing)
        : listingDetails[listingId];
    final title = listing?['title'];
    final thumbnail = listing?['thumbnail_url'];
    return ChatRoom(
      id: id,
      participants: List.unmodifiable([first, second]),
      listingId: listingId,
      listingTitle: title is String ? title : 'Listing unavailable',
      listingThumb: thumbnail is String ? thumbnail : '',
      lastMessage: lastMessage,
      lastMessageAt: lastMessageAt,
      unreadCount: Map.unmodifiable(unreadCount),
      createdAt: createdAt,
    );
  }

  ChatMessagePage _messagePage(List<Map<String, dynamic>> rows, int limit) {
    final items = rows.map(_messageFromRow).toList(growable: false);
    return ChatMessagePage(
      items: items,
      nextCursor: items.length < limit
          ? null
          : ChatCursor(createdAt: items.last.createdAt, id: items.last.id),
    );
  }

  ChatMessage _messageFromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final senderId = row['sender_id'];
    final text = row['message'];
    final createdAt = _parseDate(row['created_at']);
    if (id is! String ||
        senderId is! String ||
        text is! String ||
        createdAt == null) {
      throw const AppException('A chat message contains invalid data.');
    }
    return ChatMessage(
      id: id,
      senderId: senderId,
      text: text,
      createdAt: createdAt,
    );
  }

  DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  void _requireUser([String? expectedId]) {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in to use chat.');
    }
    if (expectedId != null && user.id != expectedId) {
      throw const AppException('You can only use chat with your own account.');
    }
  }

  void _requireUuid(String value, String kind) {
    if (!_uuidPattern.hasMatch(value)) {
      throw AppException('The $kind identifier is invalid.');
    }
  }

  void _requirePageLimit(int limit) {
    if (limit < 1 || limit > 100) {
      throw const AppException('Page size must be between 1 and 100.');
    }
  }

  AppException _mapDatabaseError(PostgrestException error, String operation) {
    final message = switch (error.code) {
      '42501' => 'You are not allowed to $operation.',
      'P0001' => error.message,
      '23503' => 'The listing or chat is no longer available.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}
