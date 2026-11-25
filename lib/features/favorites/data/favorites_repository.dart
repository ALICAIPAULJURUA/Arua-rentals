import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../listings/data/listing.dart';

class FavoriteCursor {
  const FavoriteCursor({required this.createdAt, required this.listingId});

  final DateTime createdAt;
  final String listingId;
}

class FavoriteListing {
  const FavoriteListing({
    required this.listingId,
    required this.createdAt,
    required this.listing,
  });

  final String listingId;
  final DateTime createdAt;
  final Listing? listing;

  String get title => listing?.title.isNotEmpty == true
      ? listing!.title
      : 'Listing unavailable';

  String get thumbnailUrl {
    final value = listing;
    if (value == null) return '';
    if (value.thumbnailUrl.isNotEmpty) return value.thumbnailUrl;
    return value.imageUrls.isEmpty ? '' : value.imageUrls.first;
  }

  int get priceUgx => listing?.priceUgx ?? 0;
  String get area => listing?.area ?? '';
  bool get isAvailable => listing?.status == ListingStatus.approved;
}

class FavoriteListingsPage {
  const FavoriteListingsPage({required this.items, required this.nextCursor});

  final List<FavoriteListing> items;
  final FavoriteCursor? nextCursor;
}

class FavoritesRepository {
  FavoritesRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  static const _bucket = 'listing-images';
  static const _signedUrlLifetimeSeconds = 3600;
  static const _signedUrlBatchSize = 100;
  static const _listingSelection = '''
    *,
    categories(name),
    areas(name),
    listing_images(image_url, storage_path, display_order)
  ''';

  final SupabaseClient _client;

  Future<bool> isSaved(String uid, String listingId) async {
    _requireOwner(uid);
    _requireListingId(listingId);
    try {
      final row = await _client
          .from('favorites')
          .select('listing_id')
          .eq('user_id', uid)
          .eq('listing_id', listingId)
          .maybeSingle();
      return row != null;
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'check this saved listing');
    }
  }

  Future<void> setSaved(
    String uid,
    Listing listing, {
    required bool saved,
  }) async {
    _requireOwner(uid);
    _requireListingId(listing.id);
    try {
      if (saved) {
        await _client.from('favorites').upsert({
          'user_id': uid,
          'listing_id': listing.id,
        }, onConflict: 'user_id,listing_id');
        return;
      }
      await _client
          .from('favorites')
          .delete()
          .eq('user_id', uid)
          .eq('listing_id', listing.id);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'save this listing');
    }
  }

  Future<void> remove(String uid, String listingId) async {
    _requireOwner(uid);
    _requireListingId(listingId);
    try {
      await _client
          .from('favorites')
          .delete()
          .eq('user_id', uid)
          .eq('listing_id', listingId);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'remove this saved listing');
    }
  }

  Future<FavoriteListingsPage> getPage(
    String uid, {
    int limit = 20,
    FavoriteCursor? startAfter,
  }) async {
    _requireOwner(uid);
    if (limit < 1 || limit > 100) {
      throw const AppException('Page size must be between 1 and 100.');
    }
    if (startAfter != null) _requireListingId(startAfter.listingId);
    try {
      var query = _client
          .from('favorites')
          .select('listing_id, created_at, listings($_listingSelection)')
          .eq('user_id', uid);
      if (startAfter != null) {
        final timestamp = startAfter.createdAt.toUtc().toIso8601String();
        query = query.or(
          'created_at.lt.$timestamp,'
          'and(created_at.eq.$timestamp,listing_id.lt.${startAfter.listingId})',
        );
      }
      final rows = await query
          .order('created_at', ascending: false)
          .order('listing_id', ascending: false)
          .limit(limit);
      final hydratedRows = await _resolveStorageImageUrls(rows);
      final items = <FavoriteListing>[];
      for (final row in hydratedRows) {
        final id = row['listing_id'];
        final rawCreatedAt = row['created_at'];
        final createdAt = rawCreatedAt is String
            ? DateTime.tryParse(rawCreatedAt)
            : null;
        if (id is! String || createdAt == null) {
          throw const AppException('A saved listing contains invalid data.');
        }
        final embedded = row['listings'];
        final listing = embedded is Map
            ? Listing.fromSupabaseRow(Map<String, dynamic>.from(embedded))
            : null;
        items.add(
          FavoriteListing(
            listingId: id,
            createdAt: createdAt,
            listing: listing,
          ),
        );
      }
      final nextCursor = items.length < limit
          ? null
          : FavoriteCursor(
              createdAt: items.last.createdAt,
              listingId: items.last.listingId,
            );
      return FavoriteListingsPage(items: items, nextCursor: nextCursor);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load saved listings');
    } on StorageException catch (error) {
      throw AppException(
        'Unable to load saved listing images. Please try again.',
        code: error.statusCode,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _resolveStorageImageUrls(
    List<Map<String, dynamic>> rows,
  ) async {
    final resolved = rows.map((row) => Map<String, dynamic>.from(row)).toList();
    final allPaths = <String>[];
    for (final row in resolved) {
      final embedded = row['listings'];
      if (embedded is! Map) continue;
      final listing = Map<String, dynamic>.from(embedded);
      row['listings'] = listing;
      final rawImages = listing['listing_images'];
      if (rawImages is! List) continue;
      final images = [
        for (final rawImage in rawImages)
          if (rawImage is Map) Map<String, dynamic>.from(rawImage),
      ];
      listing['listing_images'] = images;
      for (final image in images) {
        final path = image['storage_path'];
        if (path is String) allPaths.add(path);
      }
    }
    if (allPaths.isEmpty) return resolved;

    final signedUrls = <String, String>{};
    final bucket = _client.storage.from(_bucket);
    for (var start = 0; start < allPaths.length; start += _signedUrlBatchSize) {
      final end = (start + _signedUrlBatchSize).clamp(0, allPaths.length);
      final results = await bucket.createSignedUrlsResult(
        allPaths.sublist(start, end),
        _signedUrlLifetimeSeconds,
      );
      for (final result in results) {
        switch (result) {
          case SignedUrlSuccess(:final path, :final signedUrl):
            signedUrls[path] = signedUrl;
          case SignedUrlFailure():
            throw const AppException(
              'A saved listing image is unavailable. Please try again later.',
            );
        }
      }
    }
    for (final row in resolved) {
      final embedded = row['listings'];
      if (embedded is! Map) continue;
      final listing = Map<String, dynamic>.from(embedded);
      final rawImages = listing['listing_images'];
      if (rawImages is! List) continue;
      listing['listing_images'] = [
        for (final rawImage in rawImages)
          if (rawImage is Map)
            _withSignedUrl(Map<String, dynamic>.from(rawImage), signedUrls),
      ];
      row['listings'] = listing;
    }
    return resolved;
  }

  Map<String, dynamic> _withSignedUrl(
    Map<String, dynamic> image,
    Map<String, String> signedUrls,
  ) {
    final path = image['storage_path'];
    if (path is String) image['image_url'] = signedUrls[path];
    return image;
  }

  void _requireOwner(String uid) {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in to manage saved listings.');
    }
    if (uid != user.id) {
      throw const AppException('You can only manage your own saved listings.');
    }
  }

  void _requireListingId(String listingId) {
    if (!_isUuid(listingId)) {
      throw const AppException('The listing identifier is invalid.');
    }
  }

  bool _isUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  AppException _mapDatabaseError(PostgrestException error, String operation) {
    final message = switch (error.code) {
      '42501' => 'You are not allowed to $operation.',
      '23503' => 'This listing is no longer available.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}
