import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';

class PickedMediaFile {
  const PickedMediaFile({
    required this.name,
    required this.bytes,
    this.path,
    this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String? path;
  final String? mimeType;

  int get sizeInBytes => bytes.length;
}

class UploadedListingImage {
  const UploadedListingImage({required this.storagePath});

  final String storagePath;
}

class UploadedListingVideo {
  const UploadedListingVideo({
    required this.storagePath,
    required this.contentType,
  });

  final String storagePath;
  final String contentType;
}

abstract class MediaUploader {
  Future<List<String>> uploadImages(List<String> imageSources);

  Future<List<UploadedListingImage>> uploadPickedImages(
    List<PickedMediaFile> images, {
    required String listingId,
    String? ownerId,
    void Function(int index, String storagePath)? onUploadStarted,
    void Function(int index, String storagePath, double progress)? onProgress,
  });

  Future<UploadedListingVideo> uploadPickedVideo(
    PickedMediaFile video, {
    required String listingId,
    String? ownerId,
    required CancelToken cancelToken,
    void Function(double progress)? onProgress,
  });

  Future<void> deleteImages(List<String> storagePaths);

  Future<void> deleteVideo(String storagePath);

  void dispose();
}

class ListingMediaValidator {
  static const maxImages = 8;
  static const maxImageBytes = 6 * 1024 * 1024;
  static const maxVideoBytes = 50 * 1024 * 1024;

  static (String, String) imageFormat(PickedMediaFile file) {
    if (file.bytes.isEmpty || file.bytes.length > maxImageBytes) {
      throw const FormatException('Each image must be no larger than 6 MiB.');
    }

    final detected = _detectImage(file.bytes);
    final extension = _extension(file.name);
    if (detected == null || !_matchesImageExtension(detected.$2, extension)) {
      throw const FormatException(
        'Choose a valid JPG, JPEG, PNG, or WebP image.',
      );
    }
    return detected;
  }

  static (String, String) videoFormat(PickedMediaFile file) {
    if (file.bytes.isEmpty || file.bytes.length > maxVideoBytes) {
      throw const FormatException('The video must be no larger than 50 MiB.');
    }

    final extension = _extension(file.name);
    final detected = _detectVideo(file.bytes);
    if (detected == null ||
        (detected.$2 == 'mp4' && extension != 'mp4') ||
        (detected.$2 == 'webm' && extension != 'webm')) {
      throw const FormatException(
        'Choose a valid MP4 or WebM video. MOV files are not supported.',
      );
    }
    return detected;
  }

  static (String, String)? _detectImage(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return ('image/jpeg', 'jpg');
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return ('image/png', 'png');
    }
    if (bytes.length >= 12 &&
        _ascii(bytes, 0, 4) == 'RIFF' &&
        _ascii(bytes, 8, 4) == 'WEBP') {
      return ('image/webp', 'webp');
    }
    return null;
  }

  static (String, String)? _detectVideo(Uint8List bytes) {
    if (bytes.length >= 12 && _ascii(bytes, 4, 4) == 'ftyp') {
      return ('video/mp4', 'mp4');
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3) {
      return ('video/webm', 'webm');
    }
    return null;
  }

  static String _ascii(Uint8List bytes, int start, int length) =>
      String.fromCharCodes(bytes.sublist(start, start + length));

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static bool _matchesImageExtension(String format, String extension) =>
      format == 'jpg'
          ? extension == 'jpg' || extension == 'jpeg'
          : extension == format;
}

class SupabaseMediaUploader implements MediaUploader {
  SupabaseMediaUploader({SupabaseClient? client, Dio? uploadClient})
    : _client = client ?? Supabase.instance.client,
      _uploadClient = uploadClient ?? Dio(),
      _ownsUploadClient = uploadClient == null;

  static const _imageBucket = 'listing-images';
  static const _videoBucket = 'listing-videos';
  static final _random = Random.secure();

  final SupabaseClient _client;
  final Dio _uploadClient;
  final bool _ownsUploadClient;

  @override
  Future<List<String>> uploadImages(List<String> imageSources) async {
    if (imageSources.length > ListingMediaValidator.maxImages) {
      throw const FormatException('A listing can have at most 8 images.');
    }
    return imageSources
        .map((source) {
          final value = source.trim();
          final uri = Uri.tryParse(value);
          if (uri == null ||
              !uri.hasScheme ||
              !const {'http', 'https'}.contains(uri.scheme) ||
              uri.host.isEmpty ||
              value.length > 2048 ||
              value.contains(RegExp(r'\s'))) {
            throw const FormatException('Enter a valid image URL.');
          }
          return uri.toString();
        })
        .toList(growable: false);
  }

  @override
  Future<List<UploadedListingImage>> uploadPickedImages(
    List<PickedMediaFile> images, {
    required String listingId,
    String? ownerId,
    void Function(int index, String storagePath)? onUploadStarted,
    void Function(int index, String storagePath, double progress)? onProgress,
  }) async {
    if (images.length > ListingMediaValidator.maxImages) {
      throw const FormatException('A listing can have at most 8 images.');
    }
    if (images.isEmpty) return const [];
    final uploadTarget = await _requireUploadTarget(listingId, ownerId);
    final attemptedPaths = <String>[];
    try {
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final (contentType, extension) =
            ListingMediaValidator.imageFormat(image);
        final path = _newPath(uploadTarget.ownerId, listingId, index, extension);
        attemptedPaths.add(path);
        onUploadStarted?.call(index, path);
        await _upload(
          bucket: _imageBucket,
          path: path,
          bytes: image.bytes,
          contentType: contentType,
          accessToken: uploadTarget.accessToken,
          apiKey: uploadTarget.apiKey,
          onProgress: (sent, total) {
            if (total > 0) onProgress?.call(index, path, sent / total);
          },
        );
      }
      return [
        for (final path in attemptedPaths)
          UploadedListingImage(storagePath: path),
      ];
    } on DioException catch (error) {
      await _cleanupAfterFailure(_imageBucket, attemptedPaths);
      throw _mapUploadError(error, 'listing images');
    } catch (error, stackTrace) {
      await _cleanupAfterFailure(_imageBucket, attemptedPaths);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<UploadedListingVideo> uploadPickedVideo(
    PickedMediaFile video, {
    required String listingId,
    String? ownerId,
    required CancelToken cancelToken,
    void Function(double progress)? onProgress,
  }) async {
    final (contentType, extension) = ListingMediaValidator.videoFormat(video);
    final uploadTarget = await _requireUploadTarget(listingId, ownerId);
    final path = _newPath(uploadTarget.ownerId, listingId, 0, extension);
    try {
      await _upload(
        bucket: _videoBucket,
        path: path,
        bytes: video.bytes,
        contentType: contentType,
        accessToken: uploadTarget.accessToken,
        apiKey: uploadTarget.apiKey,
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          if (total > 0) onProgress?.call(sent / total);
        },
      );
      return UploadedListingVideo(storagePath: path, contentType: contentType);
    } on DioException catch (error) {
      await _cleanupAfterFailure(_videoBucket, [path]);
      throw _mapUploadError(error, 'listing video');
    } catch (error, stackTrace) {
      await _cleanupAfterFailure(_videoBucket, [path]);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> deleteImages(List<String> storagePaths) async {
    await _deletePaths(_imageBucket, storagePaths);
  }

  @override
  Future<void> deleteVideo(String storagePath) async {
    await _deletePaths(_videoBucket, [storagePath]);
  }

  Future<void> _deletePaths(String bucketName, List<String> paths) async {
    if (paths.isEmpty) return;
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in before removing listing media.');
    }
    for (final path in paths) {
      _assertOwnedPath(user, path);
    }
    try {
      await _client.storage.from(bucketName).remove(paths);
    } on StorageException catch (error) {
      throw AppException(
        'Unable to remove listing media.',
        code: error.statusCode,
      );
    }
  }

  Future<_UploadTarget> _requireUploadTarget(
    String listingId,
    String? ownerId,
  ) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in before uploading listing media.');
    }
    if (!_isUuid(listingId)) {
      throw const AppException('The listing identifier is invalid.');
    }
    final pathOwnerId = ownerId?.trim() ?? user.id;
    if (!_isUuid(pathOwnerId)) {
      throw const AppException('The listing owner identifier is invalid.');
    }
    if (pathOwnerId != user.id && !_hasAdminAccess(user)) {
      throw const AppException(
        'Only an administrator can upload media for another owner.',
      );
    }
    final session = await _client.auth.getSession();
    if (session == null) {
      throw const AppException('Your session expired. Sign in and try again.');
    }
    final apiKey = _client.auth.headers['apikey'];
    if (apiKey == null || apiKey.isEmpty) {
      throw const AppException('Supabase is not configured for media uploads.');
    }
    return _UploadTarget(
      ownerId: pathOwnerId,
      accessToken: session.accessToken,
      apiKey: apiKey,
    );
  }

  Future<void> _upload({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
    required String accessToken,
    required String apiKey,
    CancelToken? cancelToken,
    required void Function(int sent, int total) onProgress,
  }) async {
    final storageBase = _client.storage.from(bucket).url;
    final uri = Uri.parse(storageBase).replace(
      pathSegments: [
        ...Uri.parse(storageBase).pathSegments.where((segment) => segment.isNotEmpty),
        'object',
        bucket,
        ...path.split('/'),
      ],
    );
    try {
      await _uploadClient.postUri<void>(
        uri,
        data: bytes,
        cancelToken: cancelToken,
        options: Options(
          contentType: contentType,
          headers: {
            'apikey': apiKey,
            'Authorization': 'Bearer $accessToken',
            'Cache-Control': 'max-age=3600',
            'x-upsert': 'false',
          },
        ),
        onSendProgress: onProgress,
      );
    } on DioException {
      rethrow;
    }
  }

  String _newPath(
    String ownerId,
    String listingId,
    int index,
    String extension,
  ) =>
      '$ownerId/$listingId/'
      '${DateTime.now().microsecondsSinceEpoch}_'
      '${_random.nextInt(1 << 32).toRadixString(16)}_$index.$extension';

  Future<void> _cleanupAfterFailure(
    String bucket,
    List<String> uploadedPaths,
  ) async {
    if (uploadedPaths.isEmpty) return;
    try {
      await _client.storage.from(bucket).remove(uploadedPaths);
    } on StorageException catch (error) {
      throw AppException(
        'The media upload failed and temporary files could not be removed.',
        code: error.statusCode,
      );
    }
  }

  AppException _mapUploadError(DioException error, String mediaLabel) {
    if (CancelToken.isCancel(error)) {
      return AppException('The $mediaLabel upload was canceled.');
    }
    final status = error.response?.statusCode;
    final code = status?.toString();
    if (status == 401 || status == 403) {
      return AppException(
        'Your session or upload permissions have expired. Sign in and try again.',
        code: code,
      );
    }
    return AppException(
      'Unable to upload $mediaLabel. Check your connection and try again.',
      code: code,
    );
  }

  void _assertOwnedPath(User user, String path) {
    final parts = path.split('/');
    if (parts.length != 3 ||
        !_isUuid(parts[0]) ||
        !_isUuid(parts[1]) ||
        parts[2].isEmpty ||
        (parts[0] != user.id && !_hasAdminAccess(user))) {
      throw const AppException(
        'You do not have permission to remove this listing media.',
      );
    }
  }

  bool _hasAdminAccess(User user) =>
      user.appMetadata['admin'] == true ||
      user.appMetadata['super_admin'] == true;

  bool _isUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  @override
  void dispose() {
    if (_ownsUploadClient) _uploadClient.close(force: true);
  }
}

class _UploadTarget {
  const _UploadTarget({
    required this.ownerId,
    required this.accessToken,
    required this.apiKey,
  });

  final String ownerId;
  final String accessToken;
  final String apiKey;
}
