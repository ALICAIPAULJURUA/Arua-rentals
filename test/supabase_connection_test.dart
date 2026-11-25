import 'dart:io';

import 'package:arua_rentals/core/config/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryGotrueStorage extends GotrueAsyncStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> getItem({required String key}) async => _values[key];

  @override
  Future<void> removeItem({required String key}) async {
    _values.remove(key);
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    _values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'can reach the configured Supabase project and application tables',
    () async {
      if (!const bool.fromEnvironment('RUN_SUPABASE_SMOKE_TEST')) {
        return;
      }

      SupabaseConfig.validate();
      HttpOverrides.global = null;
      await Supabase.initialize(
        url: SupabaseConfig.projectUrl,
        publishableKey: SupabaseConfig.publishableKey,
        debug: false,
        authOptions: FlutterAuthClientOptions(
          localStorage: const EmptyLocalStorage(),
          pkceAsyncStorage: _MemoryGotrueStorage(),
          persistSession: false,
        ),
      );

      final client = Supabase.instance.client;
      for (final table in const [
        'profiles',
        'categories',
        'areas',
        'listings',
        'listing_images',
        'role_requests',
        'favorites',
        'chat_rooms',
        'chat_messages',
        'chat_message_reads',
      ]) {
        final rows = await client.from(table).select().limit(0);
        expect(
          rows,
          isA<List<dynamic>>(),
          reason: '$table is in the schema cache',
        );
      }
    },
  );
}
