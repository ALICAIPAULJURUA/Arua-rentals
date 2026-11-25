import '../../../core/errors/app_exception.dart';

enum ListingType { property, service }

enum ListingStatus { pending, approved, rejected }

enum ListingPriceUnit { month, job, hour, fixed }

class ListingGeoPoint {
  const ListingGeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class Listing {
  const Listing({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.ownerPhone,
    required this.type,
    required this.category,
    required this.title,
    required this.description,
    required this.priceUgx,
    required this.priceUnit,
    required this.area,
    required this.amenities,
    required this.imageUrls,
    this.imageStoragePaths = const [],
    required this.thumbnailUrl,
    required this.searchKeywords,
    required this.status,
    required this.ratingAvg,
    required this.ratingCount,
    required this.isFeatured,
    this.ownerVerified = false,
    this.titleLower,
    this.address,
    this.geo,
    this.bedrooms,
    this.bathrooms,
    this.videoUrl,
    this.videoStoragePath,
    this.rejectionReason,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String ownerName;
  final String ownerPhone;
  final ListingType type;
  final String category;
  final String title;
  final String? titleLower;
  final String description;
  final int priceUgx;
  final ListingPriceUnit priceUnit;
  final String area;
  final String? address;
  final ListingGeoPoint? geo;
  final int? bedrooms;
  final int? bathrooms;
  final List<String> amenities;
  final List<String> imageUrls;
  final List<String?> imageStoragePaths;
  final String thumbnailUrl;
  final String? videoUrl;
  final String? videoStoragePath;
  final ListingStatus status;
  final String? rejectionReason;
  final double ratingAvg;
  final int ratingCount;
  final List<String> searchKeywords;
  final bool isFeatured;
  final bool ownerVerified;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Listing.fromSupabaseRow(Map<String, dynamic> data) {
    String requiredString(String key) {
      final value = data[key];
      if (value is! String) {
        throw AppException('The listing contains invalid $key data.');
      }
      return value;
    }

    String relatedName(String key, String foreignKey) {
      final related = data[key];
      if (related is Map && related['name'] is String) {
        return related['name'] as String;
      }
      final id = data[foreignKey];
      if (id is String) return id;
      throw AppException('The listing contains invalid $key data.');
    }

    DateTime? timestamp(String key) {
      final value = data[key];
      if (value == null) return null;
      if (value is! String) {
        throw AppException('The listing contains invalid $key data.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw AppException('The listing contains invalid $key data.');
      }
      return parsed;
    }

    final type = ListingType.values.where(
      (value) => value.name == data['type'],
    );
    final status = ListingStatus.values.where(
      (value) => value.name == data['status'],
    );
    final priceUnit = ListingPriceUnit.values.where(
      (value) => value.name == data['price_unit'],
    );
    final price = data['price_ugx'];
    final ratingAvg = data['rating_avg'];
    final ratingCount = data['rating_count'];
    final amenities = data['amenities'];
    final rawImages = data['listing_images'];
    final latitude = data['latitude'];
    final longitude = data['longitude'];
    final ownerVerified = data['owner_verified'];
    final isFeatured = data['is_featured'];
    if (type.isEmpty ||
        status.isEmpty ||
        priceUnit.isEmpty ||
        price is! num ||
        price != price.toInt() ||
        ratingAvg is! num ||
        ratingCount is! num ||
        amenities is! List ||
        amenities.any((value) => value is! String) ||
        (rawImages != null &&
            (rawImages is! List || rawImages.any((value) => value is! Map))) ||
        (latitude != null && latitude is! num) ||
        (longitude != null && longitude is! num) ||
        (ownerVerified != null && ownerVerified is! bool) ||
        isFeatured is! bool) {
      throw const AppException('The listing contains invalid data.');
    }

    final images =
        rawImages == null
              ? <Map<String, dynamic>>[]
              : rawImages
                    .cast<Map>()
                    .map((image) => Map<String, dynamic>.from(image))
                    .toList()
          ..sort(
            (left, right) => (left['display_order'] as num? ?? 0).compareTo(
              right['display_order'] as num? ?? 0,
            ),
          );
    final imageUrls = <String>[];
    final imageStoragePaths = <String?>[];
    for (final image in images) {
      final url = image['image_url'];
      final path = image['storage_path'];
      if (path != null && path is! String) {
        throw const AppException('The listing contains invalid image data.');
      }
      if (url is String) {
        imageUrls.add(url);
      } else if (url == null && path is String) {
        imageUrls.add('');
      } else {
        throw const AppException('The listing contains invalid image data.');
      }
      imageStoragePaths.add(path as String?);
    }
    final thumbnail = data['thumbnail_url'];
    if (thumbnail != null && thumbnail is! String) {
      throw const AppException('The listing contains invalid thumbnail data.');
    }
    final bedrooms = data['bedrooms'];
    final bathrooms = data['bathrooms'];
    if ((bedrooms != null && bedrooms is! num) ||
        (bathrooms != null && bathrooms is! num)) {
      throw const AppException('The listing contains invalid room-count data.');
    }
    final titleLower = data['title_lower'];
    final address = data['address'];
    final videoUrl = data['video_url'];
    final videoStoragePath = data['video_storage_path'];
    final rejectionReason = data['rejection_reason'];
    if ((titleLower != null && titleLower is! String) ||
        (address != null && address is! String) ||
        (videoUrl != null && videoUrl is! String) ||
        (videoStoragePath != null && videoStoragePath is! String) ||
        (rejectionReason != null && rejectionReason is! String)) {
      throw const AppException('The listing contains invalid optional data.');
    }

    final createdAt = timestamp('created_at');
    final updatedAt = timestamp('updated_at');
    return Listing(
      id: requiredString('id'),
      ownerId: requiredString('owner_id'),
      ownerName: requiredString('owner_name'),
      ownerPhone: requiredString('owner_phone'),
      type: type.first,
      category: relatedName('categories', 'category_id'),
      title: requiredString('title'),
      titleLower: titleLower as String?,
      description: requiredString('description'),
      priceUgx: price.toInt(),
      priceUnit: priceUnit.first,
      area: relatedName('areas', 'area_id'),
      address: address as String?,
      geo: latitude == null || longitude == null
          ? null
          : ListingGeoPoint(
              latitude: (latitude as num).toDouble(),
              longitude: (longitude as num).toDouble(),
            ),
      bedrooms: (bedrooms as num?)?.toInt(),
      bathrooms: (bathrooms as num?)?.toInt(),
      amenities: List<String>.unmodifiable(amenities.cast<String>()),
      imageUrls: List<String>.unmodifiable(imageUrls),
      imageStoragePaths: List<String?>.unmodifiable(imageStoragePaths),
      thumbnailUrl: imageUrls.firstWhere(
        (url) => url.isNotEmpty,
        orElse: () => thumbnail as String? ?? '',
      ),
      videoUrl: videoUrl as String?,
      videoStoragePath: videoStoragePath as String?,
      status: status.first,
      rejectionReason: rejectionReason as String?,
      ratingAvg: ratingAvg.toDouble(),
      ratingCount: ratingCount.toInt(),
      searchKeywords: const [],
      isFeatured: isFeatured,
      ownerVerified: ownerVerified == true,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Listing copyWith({
    String? id,
    String? ownerId,
    String? ownerName,
    String? ownerPhone,
    ListingType? type,
    String? category,
    String? title,
    String? description,
    int? priceUgx,
    ListingPriceUnit? priceUnit,
    String? area,
    String? address,
    ListingGeoPoint? geo,
    int? bedrooms,
    int? bathrooms,
    List<String>? amenities,
    List<String>? imageUrls,
    List<String?>? imageStoragePaths,
    String? thumbnailUrl,
    String? videoUrl,
    String? videoStoragePath,
    ListingStatus? status,
    String? rejectionReason,
    double? ratingAvg,
    int? ratingCount,
    List<String>? searchKeywords,
    bool? isFeatured,
    bool? ownerVerified,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearRejectionReason = false,
    bool clearVideo = false,
  }) => Listing(
    id: id ?? this.id,
    ownerId: ownerId ?? this.ownerId,
    ownerName: ownerName ?? this.ownerName,
    ownerPhone: ownerPhone ?? this.ownerPhone,
    type: type ?? this.type,
    category: category ?? this.category,
    title: title ?? this.title,
    description: description ?? this.description,
    priceUgx: priceUgx ?? this.priceUgx,
    priceUnit: priceUnit ?? this.priceUnit,
    area: area ?? this.area,
    address: address ?? this.address,
    geo: geo ?? this.geo,
    bedrooms: bedrooms ?? this.bedrooms,
    bathrooms: bathrooms ?? this.bathrooms,
    amenities: amenities ?? this.amenities,
    imageUrls: imageUrls ?? this.imageUrls,
    imageStoragePaths: imageStoragePaths ?? this.imageStoragePaths,
    thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    videoUrl: clearVideo ? null : videoUrl ?? this.videoUrl,
    videoStoragePath: clearVideo
        ? null
        : videoStoragePath ?? this.videoStoragePath,
    status: status ?? this.status,
    rejectionReason: clearRejectionReason
        ? null
        : rejectionReason ?? this.rejectionReason,
    ratingAvg: ratingAvg ?? this.ratingAvg,
    ratingCount: ratingCount ?? this.ratingCount,
    searchKeywords: searchKeywords ?? this.searchKeywords,
    isFeatured: isFeatured ?? this.isFeatured,
    ownerVerified: ownerVerified ?? this.ownerVerified,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
