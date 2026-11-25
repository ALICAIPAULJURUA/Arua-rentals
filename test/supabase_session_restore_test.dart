import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemorySessionStorage extends LocalStorage {
  _MemorySessionStorage(this.value);

  String? value;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => value != null;

  @override
  Future<String?> accessToken() async => value;

  @override
  Future<void> removePersistedSession() async {
    value = null;
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    value = persistSessionString;
  }
}

class _MemoryPkceStorage extends GotrueAsyncStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> getItem({required String key}) async => values[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restores a persisted Supabase session during client initialization',
    () async {
      final storedSession = jsonEncode({
        'access_token': 'eyJhbGciOiJub25lIn0.eyJleHAiOjQ3MDAwMDAwMDB9.',
        'refresh_token': 'persisted-refresh-token',
        'expires_in': 3600,
        'token_type': 'bearer',
        'user': {
          'id': '5f6563bf-1b9f-45bf-94a4-a19161d3810a',
          'aud': 'authenticated',
          'role': 'authenticated',
          'email': 'restored@example.com',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2026-01-01T00:00:00.000Z',
        },
      });
      final storage = _MemorySessionStorage(storedSession);
      final supabase = await Supabase.initialize(
        url: 'https://restore-test.supabase.co',
        publishableKey: 'sb_publishable_test',
        httpClient: MockClient(
          (request) async => http.Response('', 500, request: request),
        ),
        authOptions: FlutterAuthClientOptions(
          persistSession: true,
          localStorage: storage,
          pkceAsyncStorage: _MemoryPkceStorage(),
          detectSessionInUri: false,
          autoRefreshToken: false,
        ),
        debug: false,
      );
      addTearDown(supabase.dispose);

      expect(supabase.client.auth.currentUser?.email, 'restored@example.com');
      expect(
        supabase.client.auth.currentSession?.refreshToken,
        'persisted-refresh-token',
      );
    },
  );
}
