import 'dart:convert';
import 'dart:typed_data';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/listings/data/media_uploader.dart';
import 'package:dio/dio.dart';
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

PickedMediaFile _png({String name = 'room.png', int size = 16}) =>
    PickedMediaFile(
      name: name,
      bytes: Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        ...List<int>.filled(size > 8 ? size - 8 : 0, 1),
      ]),
      mimeType: 'image/png',
    );

PickedMediaFile _jpeg({String name = 'room.jpg', int size = 16}) =>
    PickedMediaFile(
      name: name,
      bytes: Uint8List.fromList([
        0xff,
        0xd8,
        0xff,
        ...List<int>.filled(size > 3 ? size - 3 : 0, 1),
      ]),
      mimeType: 'image/jpeg',
    );

PickedMediaFile _webp({String name = 'room.webp', int size = 16}) =>
    PickedMediaFile(
      name: name,
      bytes: Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50, // WEBP
        ...List<int>.filled(size > 12 ? size - 12 : 0, 1),
      ]),
      mimeType: 'image/webp',
    );

PickedMediaFile _mp4({String name = 'tour.mp4', int size = 16}) =>
    PickedMediaFile(
      name: name,
      bytes: Uint8List.fromList([
        0, 0, 0, 24,
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x69, 0x73, 0x6f, 0x6d,
        ...List<int>.filled(size > 12 ? size - 12 : 0, 1),
      ]),
      mimeType: 'video/mp4',
    );

PickedMediaFile _webm({String name = 'tour.webm', int size = 16}) =>
    PickedMediaFile(
      name: name,
      bytes: Uint8List.fromList([
        0x1a, 0x45, 0xdf, 0xa3,
        ...List<int>.filled(size > 4 ? size - 4 : 0, 1),
      ]),
      mimeType: 'video/webm',
    );

Future<SupabaseClient> _signedInClient({
  required MockClient httpClient,
  String email = 'landlord@example.test',
  bool admin = false,
}) async {
  final client = SupabaseClient(
    'https://test-project.supabase.co',
    'sb_publishable_test',
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    httpClient: httpClient,
  );
  await client.auth.signInWithPassword(
    email: email,
    password: 'valid-test-password',
  );
  return client;
}

MockClient _authClient(
  MockClientHandler handler, {
  bool autoHandleRemove = true,
}) =>
    MockClient((request) async {
      if (request.url.path.endsWith('/auth/v1/token')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final email = body['email'] as String? ?? 'landlord@example.test';
        final admin = email == 'admin@example.test';
        return _jsonResponse(request, {
          'access_token': _accessToken,
          'refresh_token': 'test-refresh-token',
          'expires_in': 3600,
          'token_type': 'bearer',
          'user': {
            'id': _userId,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': email,
            'app_metadata': admin ? {'admin': true} : <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
            'created_at': '2026-01-01T00:00:00.000Z',
          },
        });
      }
      final response = await handler(request);
      if (response.statusCode == 404 &&
          autoHandleRemove &&
          (request.method == 'DELETE' ||
              request.url.path.contains('/storage/v1/object/') &&
                  request.url.path.contains('/remove'))) {
        return _jsonResponse(request, const <Object>[]);
      }
      return response;
    });

Dio _mockUploadDio({
  void Function(RequestOptions options)? onPost,
  DioException? rejectWith,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (rejectWith != null) {
          handler.reject(rejectWith);
          return;
        }
        if (options.method == 'POST') onPost?.call(options);
        handler.resolve(
          Response<void>(
            requestOptions: options,
            statusCode: 200,
            data: null,
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test(
    'validates external image URLs and enforces the server length limit',
    () async {
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
      );
      addTearDown(client.dispose);
      final uploader = SupabaseMediaUploader(client: client);

      expect(
        await uploader.uploadImages(['https://images.example.test/room.jpg']),
        ['https://images.example.test/room.jpg'],
      );
      for (final invalidUrl in [
        'data:image/png;base64,abc',
        'https:///room.jpg',
        'https://images.example.test/room image.jpg',
        'https://images.example.test/${'x' * 2048}',
      ]) {
        await expectLater(
          uploader.uploadImages([invalidUrl]),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test(
    'uploads image under authenticated owner/listing path without signing early',
    () async {
      final requests = <http.Request>[];
      RequestOptions? uploadOptions;
      final uploadDio = _mockUploadDio(
        onPost: (options) => uploadOptions = options,
      );
      addTearDown(() => uploadDio.close(force: true));
      final client = await _signedInClient(
        httpClient: _authClient((request) async {
          requests.add(request);
          if (request.method == 'DELETE' ||
              request.url.path.contains('/storage/v1/object/') &&
                  request.url.path.contains('/remove')) {
            return _jsonResponse(request, const <Object>[]);
          }
          return _jsonResponse(request, {
            'message': 'Unexpected request',
          }, status: 404);
        }),
      );
      addTearDown(client.dispose);

      final trackedPaths = <(int, String)>[];
      final progress = <double>[];
      final uploaded = await SupabaseMediaUploader(
        client: client,
        uploadClient: uploadDio,
      ).uploadPickedImages(
        [_png()],
        listingId: _listingId,
        onUploadStarted: (index, path) => trackedPaths.add((index, path)),
        onProgress: (_, __, value) => progress.add(value),
      );

      expect(uploaded, hasLength(1));
      expect(trackedPaths, [(0, uploaded.single.storagePath)]);
      expect(uploaded.single.storagePath, startsWith('$_userId/$_listingId/'));
      expect(uploaded.single.storagePath, endsWith('.png'));
      expect(
        requests.any(
          (request) => request.url.path.contains('/storage/v1/object/sign/'),
        ),
        isFalse,
      );
      expect(
        uploadOptions?.uri.path,
        contains('/storage/v1/object/listing-images/'),
      );
      expect(uploadOptions?.contentType, 'image/png');
      expect(uploadOptions?.headers['Authorization'], 'Bearer $_accessToken');
      expect(uploadOptions?.headers['x-upsert'], 'false');
    },
  );

  test('uses the listing owner path for an administrator upload', () async {
    const listingOwnerId = '7f6563bf-1b9f-45bf-94a4-a19161d3810a';
    final uploadDio = _mockUploadDio();
    addTearDown(() => uploadDio.close(force: true));
    final client = await _signedInClient(
      email: 'admin@example.test',
      httpClient: _authClient((request) async {
        if (request.method == 'DELETE' ||
            request.url.path.contains('/remove')) {
          return _jsonResponse(request, const <Object>[]);
        }
        return _jsonResponse(request, {'Key': request.url.path}, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final uploaded = await SupabaseMediaUploader(
      client: client,
      uploadClient: uploadDio,
    ).uploadPickedImages(
      [_png()],
      listingId: _listingId,
      ownerId: listingOwnerId,
    );

    expect(uploaded.single.storagePath, startsWith('$listingOwnerId/'));
  });

  test(
    'rejects unsupported formats and extension mismatches locally',
    () async {
      var storageRequestCount = 0;
      final uploadDio = _mockUploadDio(
        onPost: (_) => storageRequestCount++,
      );
      addTearDown(() => uploadDio.close(force: true));
      final client = await _signedInClient(
        httpClient: _authClient((request) async {
          if (request.method == 'DELETE' ||
              request.url.path.contains('/remove')) {
            return _jsonResponse(request, const <Object>[]);
          }
          return _jsonResponse(request, {'Key': 'unused'}, status: 404);
        }),
      );
      addTearDown(client.dispose);
      final uploader = SupabaseMediaUploader(
        client: client,
        uploadClient: uploadDio,
      );

      await expectLater(
        uploader.uploadPickedImages(
          [_png()],
          listingId: _listingId,
          ownerId: '7f6563bf-1b9f-45bf-94a4-a19161d3810a',
        ),
        throwsA(isA<AppException>()),
      );

      for (final image in [
        PickedMediaFile(
          name: 'room.gif',
          bytes: Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
        ),
        PickedMediaFile(
          name: 'room.png',
          bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0x00]),
        ),
      ]) {
        await expectLater(
          uploader.uploadPickedImages([image], listingId: _listingId),
          throwsA(isA<FormatException>()),
        );
      }

      await expectLater(
        () => ListingMediaValidator.videoFormat(
          PickedMediaFile(
            name: 'tour.mov',
            bytes: Uint8List.fromList([
              0, 0, 0, 24,
              0x66, 0x74, 0x79, 0x70,
              0x71, 0x74, 0x20, 0x20,
            ]),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(storageRequestCount, 0);
    },
  );

  test('rejects oversized image before calling Storage', () async {
    var uploadRequestCount = 0;
    final uploadDio = _mockUploadDio(
      onPost: (_) => uploadRequestCount++,
    );
    addTearDown(() => uploadDio.close(force: true));
    final client = await _signedInClient(
      httpClient: _authClient((request) async {
        if (request.method == 'DELETE' ||
            request.url.path.contains('/remove')) {
          return _jsonResponse(request, const <Object>[]);
        }
        return _jsonResponse(request, {'Key': request.url.path}, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final uploader = SupabaseMediaUploader(
      client: client,
      uploadClient: uploadDio,
    );
    final exactLimitUpload = await uploader.uploadPickedImages([
      _jpeg(size: ListingMediaValidator.maxImageBytes),
    ], listingId: _listingId);
    expect(exactLimitUpload, hasLength(1));
    expect(uploadRequestCount, 1);

    await expectLater(
      uploader.uploadPickedImages([
        _jpeg(
          name: 'large.jpg',
          size: ListingMediaValidator.maxImageBytes + 1,
        ),
      ], listingId: _listingId),
      throwsA(isA<FormatException>()),
    );
    expect(uploadRequestCount, 1);
  });

  test('reports the exact new path before an upload request fails', () async {
    final requests = <http.Request>[];
    final uploadDio = _mockUploadDio(
      rejectWith: DioException(
        requestOptions: RequestOptions(
          path: '/storage/v1/object/listing-images',
        ),
        response: Response(
          requestOptions: RequestOptions(
            path: '/storage/v1/object/listing-images',
          ),
          statusCode: 403,
          data: {'message': 'Upload rejected by test server'},
        ),
        type: DioExceptionType.badResponse,
      ),
    );
    addTearDown(() => uploadDio.close(force: true));
    final client = await _signedInClient(
      httpClient: _authClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE' ||
            request.url.path.contains('/remove')) {
          return _jsonResponse(request, const <Object>[]);
        }
        return _jsonResponse(request, {'Key': request.url.path}, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final trackedPaths = <(int, String)>[];
    await expectLater(
      SupabaseMediaUploader(
        client: client,
        uploadClient: uploadDio,
      ).uploadPickedImages(
        [_png()],
        listingId: _listingId,
        onUploadStarted: (index, path) => trackedPaths.add((index, path)),
      ),
      throwsA(isA<AppException>()),
    );

    expect(trackedPaths, hasLength(1));
    expect(trackedPaths.single.$1, 0);
    expect(trackedPaths.single.$2, startsWith('$_userId/$_listingId/'));
    final cleanupRequest = requests.singleWhere(
      (request) => request.method == 'DELETE',
    );
    expect(
      jsonDecode(cleanupRequest.body),
      containsPair('prefixes', [trackedPaths.single.$2]),
    );
  });

  test('requires an authenticated owner before upload', () async {
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
    );
    addTearDown(client.dispose);

    await expectLater(
      SupabaseMediaUploader(client: client).uploadPickedImages([
        _jpeg(),
      ], listingId: _listingId),
      throwsA(isA<AppException>()),
    );
  });

  test('uploads video with progress to the listing-videos bucket', () async {
    RequestOptions? uploadOptions;
    final uploadDio = _mockUploadDio(
      onPost: (options) {
        uploadOptions = options;
        options.onSendProgress?.call(5, 10);
        options.onSendProgress?.call(10, 10);
      },
    );
    addTearDown(() => uploadDio.close(force: true));
    final client = await _signedInClient(
      httpClient: _authClient((request) async {
        if (request.method == 'DELETE' ||
            request.url.path.contains('/remove')) {
          return _jsonResponse(request, const <Object>[]);
        }
        return _jsonResponse(request, {'Key': request.url.path}, status: 404);
      }),
    );
    addTearDown(client.dispose);

    final progress = <double>[];
    final uploaded = await SupabaseMediaUploader(
      client: client,
      uploadClient: uploadDio,
    ).uploadPickedVideo(
      _mp4(),
      listingId: _listingId,
      cancelToken: CancelToken(),
      onProgress: progress.add,
    );

    expect(uploaded.storagePath, startsWith('$_userId/$_listingId/'));
    expect(uploaded.storagePath, endsWith('.mp4'));
    expect(uploaded.contentType, 'video/mp4');
    expect(uploadOptions?.uri.path, contains('/storage/v1/object/listing-videos/'));
    expect(uploadOptions?.contentType, 'video/mp4');
    expect(uploadOptions?.headers['Authorization'], 'Bearer $_accessToken');
    expect(progress, contains(1.0));
  });

  test('validates video format and size locally', () async {
    expect(
      () => ListingMediaValidator.videoFormat(_webm()),
      returnsNormally,
    );
    expect(
      () => ListingMediaValidator.videoFormat(
        _mp4(size: ListingMediaValidator.maxVideoBytes + 1),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ListingMediaValidator.videoFormat(
        PickedMediaFile(
          name: 'tour.mov',
          bytes: Uint8List.fromList([
            0, 0, 0, 24,
            0x66, 0x74, 0x79, 0x70,
            0x71, 0x74, 0x20, 0x20,
          ]),
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('maps canceled video upload and cleans up the attempted path', () async {
    final requests = <http.Request>[];
    final client = await _signedInClient(
      httpClient: _authClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE' ||
            request.url.path.contains('/remove')) {
          return _jsonResponse(request, const <Object>[]);
        }
        return _jsonResponse(request, {'Key': request.url.path}, status: 404);
      }),
    );
    addTearDown(client.dispose);
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        },
      ),
    );

    await expectLater(
      SupabaseMediaUploader(client: client, uploadClient: dio).uploadPickedVideo(
        _mp4(),
        listingId: _listingId,
        cancelToken: CancelToken(),
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          contains('canceled'),
        ),
      ),
    );

    final cleanupRequest = requests.singleWhere(
      (request) =>
          request.method == 'DELETE' &&
          request.url.path.contains('/storage/v1/object/listing-videos'),
    );
    final prefixes = (jsonDecode(cleanupRequest.body)
        as Map<String, dynamic>)['prefixes'] as List;
    expect(prefixes, hasLength(1));
    expect(prefixes.single, startsWith('$_userId/$_listingId/'));
  });
}
