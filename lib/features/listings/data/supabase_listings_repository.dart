import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import 'listing.dart';
import 'listing_sort.dart';
import 'search_keywords.dart';

class ListingCursor {
  const ListingCursor({
    required this.id,
    required this.createdAt,
    required this.priceUgx,
  });

  final String id;
  final DateTime createdAt;
  final int priceUgx;
}

class SupabaseListingPage {
  const SupabaseListingPage({required this.items, required this.nextCursor});

  final List<Listing> items;
  final ListingCursor? nextCursor;
}

class SupabaseListingsRepository {
  SupabaseListingsRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  static const _imageBucket = 'listing-images';
  static const _videoBucket = 'listing-videos';
  static const _signedUrlLifetimeSeconds = 3600;
  static const _signedUrlBatchSize = 100;

  static const _selection = '''
    *,
    categories(name),
    areas(name),
    listing_images(image_url, storage_path, display_order)
  ''';

  Future<Listing?> getById(String id) async {
    if (!_isUuid(id)) return null;
    try {
      final row = await _client
          .from('listings')
          .select(_selection)
          .eq('id', id)
          .maybeSingle();
      if (row == null) return null;
      final resolved = await _resolveListingMediaUrls([row]);
      return Listing.fromSupabaseRow(resolved.single);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load this listing');
    }
  }

  Future<SupabaseListingPage> getApprovedListings({
    int limit = 20,
    ListingCursor? startAfter,
    String? category,
    String? area,
    String? keyword,
    ListingSort sort = ListingSort.newest,
  }) => _getPage(
    limit: limit,
    startAfter: startAfter,
    status: ListingStatus.approved,
    category: category,
    area: area,
    keyword: keyword,
    sort: sort,
  );

  Future<List<Listing>> getFeaturedListings({int limit = 8}) async {
    _validatePageSize(limit);
    try {
      final rows = await _client
          .from('listings')
          .select(_selection)
          .eq('status', ListingStatus.approved.name)
          .eq('is_featured', true)
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .range(0, limit - 1);
      final resolved = await _resolveListingMediaUrls(rows);
      return resolved.map(Listing.fromSupabaseRow).toList(growable: false);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load featured listings');
    }
  }

  Future<SupabaseListingPage> getOwnerListings({
    int limit = 20,
    ListingCursor? startAfter,
  }) {
    final user = _requireUser();
    return _getPage(
      limit: limit,
      startAfter: startAfter,
      ownerId: user.id,
      sort: ListingSort.newest,
    );
  }

  Future<SupabaseListingPage> getAdminListings({
    ListingStatus? status,
    int limit = 20,
    ListingCursor? startAfter,
    String? keyword,
  }) async {
    _requireAdmin();
    return _getPage(
      limit: limit,
      startAfter: startAfter,
      status: status,
      keyword: keyword,
      sort: ListingSort.newest,
    );
  }

  Future<Listing> create(
    Listing listing, {
    String? ownerId,
    void Function(String listingId)? onCreated,
  }) async {
    final user = _requireUser();
    final isAdmin = _hasAdminAccess(user);
    final effectiveOwnerId = isAdmin && ownerId != null ? ownerId : user.id;
    final requestedId = listing.id.trim();
    if (requestedId.isNotEmpty && !_isUuid(requestedId)) {
      throw const AppException('The listing identifier is invalid.');
    }
    try {
      final profile = await _client
          .from('profiles')
          .select('full_name, phone, role, is_verified')
          .eq('id', effectiveOwnerId)
          .maybeSingle();
      if (profile == null) {
        throw const AppException('The listing owner profile was not found.');
      }

      final role = profile['role'];
      if (!isAdmin && role != 'landlord' && role != 'provider') {
        throw const AppException(
          'Only approved landlords and providers can create listings.',
        );
      }
      final categoryId = await _requireOptionId('categories', listing.category);
      final areaId = await _requireOptionId('areas', listing.area);
      final ownerName = _requiredString(profile, 'full_name');
      final profilePhone = profile['phone'];
      final ownerPhone = profilePhone is String && profilePhone.trim().isNotEmpty
          ? profilePhone.trim()
          : listing.ownerPhone.trim().isNotEmpty
          ? listing.ownerPhone.trim()
          : throw const AppException(
              'Add a valid phone number to your profile or listing before saving.',
            );
      final status = isAdmin ? ListingStatus.approved : ListingStatus.pending;
      final searchKeywords = generateListingSearchKeywords(
        title: listing.title,
        category: listing.category,
        area: listing.area,
      );
      final data = _toSupabaseRow(
        listing,
        ownerId: effectiveOwnerId,
        ownerName: ownerName,
        ownerPhone: ownerPhone,
        categoryId: categoryId,
        areaId: areaId,
        status: status,
        searchKeywords: searchKeywords,
        ownerVerified: profile['is_verified'] == true,
        isFeatured: isAdmin && listing.isFeatured,
        includeProtectedFields: isAdmin,
      );
      if (requestedId.isNotEmpty) {
        data['id'] = requestedId;
        onCreated?.call(requestedId);
      }
      final inserted = await _client
          .from('listings')
          .insert(data)
          .select('id')
          .single();
      final id = inserted['id'];
      if (id is! String) {
        throw const AppException('The listing could not be saved.');
      }
      if (requestedId.isNotEmpty && id != requestedId) {
        throw const AppException(
          'The saved listing identifier did not match the requested ID.',
        );
      }
      if (requestedId.isEmpty) onCreated?.call(id);
      try {
        await _replaceImages(id, listing.imageUrls, listing.imageStoragePaths);
      } catch (error, stackTrace) {
        try {
          await _client.from('listings').delete().eq('id', id);
        } catch (_) {
          // Best-effort cleanup; preserve the original save error.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      final created = await getById(id);
      if (created == null) {
        throw const AppException(
          'The listing was saved but could not be read.',
        );
      }
      return created;
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'create this listing');
    }
  }

  Future<Listing> update(Listing listing) async {
    final user = _requireUser();
    try {
      final existingRow = await _client
          .from('listings')
          .select(_selection)
          .eq('id', listing.id)
          .maybeSingle();
      if (existingRow == null) {
        throw const AppException('This listing no longer exists.');
      }
      final existing = Listing.fromSupabaseRow(existingRow);
      final isAdmin = _hasAdminAccess(user);
      if (!isAdmin && existing.ownerId != user.id) {
        throw const AppException('You can only edit your own listings.');
      }
      final categoryId = await _requireOptionId('categories', listing.category);
      final areaId = await _requireOptionId('areas', listing.area);
      final keywords = generateListingSearchKeywords(
        title: listing.title,
        category: listing.category,
        area: listing.area,
      );
      final updated = listing.copyWith(
        ownerId: existing.ownerId,
        ownerName: existing.ownerName,
        ownerPhone: listing.ownerPhone,
        ratingAvg: existing.ratingAvg,
        ratingCount: existing.ratingCount,
        isFeatured: existing.isFeatured,
        ownerVerified: existing.ownerVerified,
        status: isAdmin ? existing.status : ListingStatus.pending,
        clearRejectionReason: !isAdmin,
      );
      final data = _toSupabaseRow(
        updated,
        ownerId: existing.ownerId,
        ownerName: existing.ownerName,
        ownerPhone: updated.ownerPhone,
        categoryId: categoryId,
        areaId: areaId,
        status: updated.status,
        searchKeywords: keywords,
        ownerVerified: existing.ownerVerified,
        isFeatured: existing.isFeatured,
        includeProtectedFields: isAdmin,
      )..remove('created_at');
      if (!isAdmin) data['rejection_reason'] = null;
      await _client.rpc(
        'update_listing_with_images',
        params: {
          'p_listing_id': listing.id,
          'p_listing_data': data,
          'p_images': _imageMetadata(
            listing.imageUrls,
            listing.imageStoragePaths,
          ),
        },
      );
      return updated;
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'update this listing');
    }
  }

  Future<void> delete(String id) async {
    _requireUser();
    try {
      await _client.from('listings').delete().eq('id', id);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'delete this listing');
    }
  }

  Future<void> setStatus(
    String id,
    ListingStatus status, {
    String? rejectionReason,
  }) async {
    _requireAdmin();
    final reason = rejectionReason?.trim();
    if (status == ListingStatus.rejected &&
        (reason == null || reason.isEmpty || reason.length > 500)) {
      throw const AppException(
        'Enter a rejection reason of 1 to 500 characters.',
      );
    }
    if (status == ListingStatus.pending) {
      throw const AppException(
        'Administrators can only approve or reject listings.',
      );
    }
    try {
      await _client.rpc(
        'review_listing',
        params: {
          'p_listing_id': id,
          'p_status': status.name,
          'p_rejection_reason': status == ListingStatus.rejected
              ? reason
              : null,
        },
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'moderate this listing');
    }
  }

  Future<SupabaseListingPage> _getPage({
    required int limit,
    required ListingSort sort,
    ListingCursor? startAfter,
    ListingStatus? status,
    String? ownerId,
    String? category,
    String? area,
    String? keyword,
  }) async {
    _validatePageSize(limit);
    try {
      var query = _client.from('listings').select(_selection);
      if (status != null) query = query.eq('status', status.name);
      if (ownerId != null) query = query.eq('owner_id', ownerId);
      if (category != null) {
        final categoryId = await _resolveOptionId(
          'categories',
          category,
          onlyActive: status == ListingStatus.approved,
        );
        if (categoryId == null) {
          return const SupabaseListingPage(items: [], nextCursor: null);
        }
        query = query.eq('category_id', categoryId);
      }
      if (area != null) {
        final areaId = await _resolveOptionId(
          'areas',
          area,
          onlyActive: status == ListingStatus.approved,
        );
        if (areaId == null) {
          return const SupabaseListingPage(items: [], nextCursor: null);
        }
        query = query.eq('area_id', areaId);
      }
      final token = keyword?.trim().toLowerCase();
      if (token != null && token.isNotEmpty) {
        query = query.contains('search_prefixes', [token]);
      }
      query = _applyCursor(query, startAfter, sort);
      final rows = await _applyOrdering(query, sort).limit(limit);
      final resolved = await _resolveListingMediaUrls(rows);
      final items = resolved
          .map(Listing.fromSupabaseRow)
          .toList(growable: false);
      return SupabaseListingPage(
        items: items,
        nextCursor: items.length < limit ? null : _cursorFor(items.last),
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load listings');
    }
  }

  Future<String?> _resolveOptionId(
    String table,
    String name, {
    bool onlyActive = true,
  }) async {
    var query = _client.from(table).select('id').eq('name', name);
    if (onlyActive) query = query.eq('is_active', true);
    final row = await query.maybeSingle();
    if (row == null) return null;
    final id = row['id'];
    if (id is! String) {
      throw const AppException(
        'The listing configuration contains invalid data.',
      );
    }
    return id;
  }

  Future<String> _requireOptionId(String table, String name) async {
    final id = await _resolveOptionId(table, name);
    if (id == null) {
      throw AppException(
        'The selected ${table == 'categories' ? 'category' : 'area'} is unavailable. '
        'Refresh the options or contact an administrator.',
      );
    }
    return id;
  }

  Future<void> _replaceImages(
    String listingId,
    List<String> imageUrls,
    List<String?> storagePaths,
  ) async {
    final images = _imageMetadata(imageUrls, storagePaths);
    if (images.isEmpty) return;
    await _client.rpc(
      'replace_listing_images',
      params: {'p_listing_id': listingId, 'p_images': images},
    );
  }

  List<Map<String, dynamic>> _imageMetadata(
    List<String> imageUrls,
    List<String?> storagePaths,
  ) => [
    for (var index = 0; index < imageUrls.length; index++)
      {
        'image_url': index < storagePaths.length && storagePaths[index] != null
            ? null
            : imageUrls[index],
        'storage_path': index < storagePaths.length
            ? storagePaths[index]
            : null,
        'display_order': index,
      },
  ];

  Future<List<Map<String, dynamic>>> _resolveListingMediaUrls(
    List<Map<String, dynamic>> rows,
  ) async {
    final resolved = rows.map((row) => Map<String, dynamic>.from(row)).toList();
    final imagePaths = <String>[];
    final videoPaths = <String>[];
    final user = _client.auth.currentUser;
    final userId = user?.id;
    final isAdmin = user != null && _hasAdminAccess(user);
    for (final row in resolved) {
      final canReadStorageImages =
          row['status'] == ListingStatus.approved.name ||
          row['owner_id'] == userId ||
          isAdmin;
      final rawImages = row['listing_images'];
      if (rawImages is List) {
        final images = [
          for (final rawImage in rawImages)
            if (rawImage is Map) Map<String, dynamic>.from(rawImage),
        ];
        row['listing_images'] = images;
        for (final image in images) {
          final path = image['storage_path'];
          if (path is String && canReadStorageImages) {
            imagePaths.add(path);
          } else if (path is String) {
            image['image_url'] = null;
          }
        }
      }
      final videoPath = row['video_url'];
      if (videoPath is String && _isListingVideoPath(videoPath)) {
        row['video_storage_path'] = videoPath;
        if (canReadStorageImages) {
          videoPaths.add(videoPath);
        } else {
          row['video_url'] = null;
        }
      }
    }

    final imageSignedUrls = <String, String>{};
    final videoSignedUrls = <String, String>{};
    try {
      for (
        var start = 0;
        start < imagePaths.length;
        start += _signedUrlBatchSize
      ) {
        final end = (start + _signedUrlBatchSize).clamp(0, imagePaths.length);
        final results = await _client.storage
            .from(_imageBucket)
            .createSignedUrlsResult(
              imagePaths.sublist(start, end),
              _signedUrlLifetimeSeconds,
            );
        for (final result in results) {
          switch (result) {
            case SignedUrlSuccess(:final path, :final signedUrl):
              imageSignedUrls[path] = signedUrl;
            case SignedUrlFailure():
              throw const AppException(
                'A listing image is unavailable. Please try again later.',
              );
          }
        }
      }
      for (
        var start = 0;
        start < videoPaths.length;
        start += _signedUrlBatchSize
      ) {
        final end = (start + _signedUrlBatchSize).clamp(0, videoPaths.length);
        final results = await _client.storage
            .from(_videoBucket)
            .createSignedUrlsResult(
              videoPaths.sublist(start, end),
              _signedUrlLifetimeSeconds,
            );
        for (final result in results) {
          switch (result) {
            case SignedUrlSuccess(:final path, :final signedUrl):
              videoSignedUrls[path] = signedUrl;
            case SignedUrlFailure():
              throw const AppException(
                'A listing video is unavailable. Please try again later.',
              );
          }
        }
      }
    } on StorageException catch (error) {
      throw AppException(
        'Unable to load listing media. Please try again.',
        code: error.statusCode,
      );
    }

    for (final row in resolved) {
      final rawImages = row['listing_images'];
      if (rawImages is List) {
        row['listing_images'] = [
          for (final rawImage in rawImages)
            if (rawImage is Map)
              _withSignedImageUrl(
                Map<String, dynamic>.from(rawImage),
                imageSignedUrls,
              ),
        ];
      }
      final videoPath = row['video_storage_path'];
      if (videoPath is String) {
        row['video_url'] = videoSignedUrls[videoPath];
      }
    }
    return resolved;
  }

  Map<String, dynamic> _withSignedImageUrl(
    Map<String, dynamic> image,
    Map<String, String> signedUrls,
  ) {
    final path = image['storage_path'];
    if (path == null) return image;
    image['image_url'] = path is String ? signedUrls[path] : null;
    return image;
  }

  PostgrestFilterBuilder<PostgrestList> _applyCursor(
    PostgrestFilterBuilder<PostgrestList> query,
    ListingCursor? cursor,
    ListingSort sort,
  ) {
    if (cursor == null) return query;
    final createdAt = cursor.createdAt.toUtc().toIso8601String();
    final priceDirection = sort == ListingSort.priceLowToHigh ? 'gt' : 'lt';
    return switch (sort) {
      ListingSort.newest => query.or(
        'created_at.lt.$createdAt,and(created_at.eq.$createdAt,id.lt.${cursor.id})',
      ),
      ListingSort.priceLowToHigh || ListingSort.priceHighToLow => query.or(
        'price_ugx.$priceDirection.${cursor.priceUgx},'
        'and(price_ugx.eq.${cursor.priceUgx},created_at.lt.$createdAt),'
        'and(price_ugx.eq.${cursor.priceUgx},created_at.eq.$createdAt,id.lt.${cursor.id})',
      ),
    };
  }

  PostgrestTransformBuilder<PostgrestList> _applyOrdering(
    PostgrestFilterBuilder<PostgrestList> query,
    ListingSort sort,
  ) => switch (sort) {
    ListingSort.newest =>
      query.order('created_at', ascending: false).order('id', ascending: false),
    ListingSort.priceLowToHigh =>
      query
          .order('price_ugx')
          .order('created_at', ascending: false)
          .order('id', ascending: false),
    ListingSort.priceHighToLow =>
      query
          .order('price_ugx', ascending: false)
          .order('created_at', ascending: false)
          .order('id', ascending: false),
  };

  Map<String, dynamic> _toSupabaseRow(
    Listing listing, {
    required String ownerId,
    required String ownerName,
    required String ownerPhone,
    required String categoryId,
    required String areaId,
    required ListingStatus status,
    required List<String> searchKeywords,
    required bool ownerVerified,
    required bool isFeatured,
    required bool includeProtectedFields,
  }) => {
    'owner_id': ownerId,
    'owner_name': ownerName,
    'owner_phone': ownerPhone,
    'type': listing.type.name,
    'category_id': categoryId,
    'area_id': areaId,
    'title': listing.title.trim(),
    'title_lower': listing.title.trim().toLowerCase(),
    'description': listing.description.trim(),
    'price_ugx': listing.priceUgx,
    'price_unit': listing.priceUnit.name,
    'address': listing.address,
    'latitude': listing.geo?.latitude,
    'longitude': listing.geo?.longitude,
    'bedrooms': listing.bedrooms,
    'bathrooms': listing.bathrooms,
    'amenities': listing.amenities,
    'thumbnail_url':
        listing.thumbnailUrl.isEmpty ||
            (listing.imageStoragePaths.isNotEmpty &&
                listing.imageStoragePaths.first != null)
        ? null
        : listing.thumbnailUrl,
    'video_url': listing.videoStoragePath ?? listing.videoUrl,
    'status': status.name,
    'rejection_reason': listing.rejectionReason,
    'search_prefixes': searchKeywords,
    if (includeProtectedFields) ...{
      'rating_avg': listing.ratingAvg,
      'rating_count': listing.ratingCount,
      'is_featured': isFeatured,
      'owner_verified': ownerVerified,
    },
  };

  ListingCursor _cursorFor(Listing listing) {
    final createdAt = listing.createdAt;
    if (createdAt == null) {
      throw const AppException('The listing is missing its creation time.');
    }
    return ListingCursor(
      id: listing.id,
      createdAt: createdAt,
      priceUgx: listing.priceUgx,
    );
  }

  User _requireUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in before managing listings.');
    }
    return user;
  }

  void _requireAdmin() {
    if (!_hasAdminAccess(_requireUser())) {
      throw const AppException('Administrator access is required.');
    }
  }

  bool _hasAdminAccess(User user) =>
      user.appMetadata['admin'] == true ||
      user.appMetadata['super_admin'] == true;

  String _requiredString(Map<String, dynamic> data, String field) {
    final value = data[field];
    if (value is! String || value.trim().isEmpty) {
      throw AppException('The listing owner profile has invalid $field data.');
    }
    return value;
  }

  void _validatePageSize(int limit) {
    if (limit < 1 || limit > 100) {
      throw const AppException('Page size must be between 1 and 100.');
    }
  }

  bool _isUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  bool _isListingVideoPath(String value) {
    final parts = value.split('/');
    return parts.length == 3 &&
        _isUuid(parts[0]) &&
        _isUuid(parts[1]) &&
        parts[2].isNotEmpty;
  }

  AppException _mapDatabaseError(PostgrestException error, String operation) {
    final message = switch (error.code) {
      '42501' => 'You are not allowed to $operation.',
      '23503' => 'The selected owner, category, or area is unavailable.',
      '23505' => 'A listing with these details already exists.',
      '22P02' => 'The listing contains invalid data.',
      '42883' || 'PGRST202' =>
        'The listing service is not configured correctly. Please contact support.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}
