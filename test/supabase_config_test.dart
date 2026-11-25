import 'package:arua_rentals/core/config/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Supabase compile-time configuration is documented but never secret',
    () {
      expect(SupabaseConfig.projectUrl, isA<String>());
      expect(SupabaseConfig.publishableKey, isA<String>());
    },
  );

  test('accepts a root project URL and non-empty publishable key', () {
    expect(
      () => SupabaseConfig.validateValues(
        projectUrl: 'https://ruxbwidezpmyuzuvtpvx.supabase.co',
        publishableKey: 'sb_publishable_test',
      ),
      returnsNormally,
    );
  });

  test('rejects missing compile-time configuration values', () {
    expect(
      () => SupabaseConfig.validateValues(
        projectUrl: '',
        publishableKey: 'sb_publishable_test',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => SupabaseConfig.validateValues(
        projectUrl: 'https://ruxbwidezpmyuzuvtpvx.supabase.co',
        publishableKey: '  ',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects REST API and other resource URLs', () {
    for (final path in ['/rest/v1', '/rest/v1/', '/auth/v1']) {
      expect(
        () => SupabaseConfig.validateValues(
          projectUrl: 'https://ruxbwidezpmyuzuvtpvx.supabase.co$path',
          publishableKey: 'sb_publishable_test',
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects non-HTTPS project URLs', () {
    expect(
      () => SupabaseConfig.validateValues(
        projectUrl: 'http://ruxbwidezpmyuzuvtpvx.supabase.co',
        publishableKey: 'sb_publishable_test',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('validates the actual compile-time configuration', () {
    expect(() => SupabaseConfig.validate(), returnsNormally);
    expect(
      SupabaseConfig.projectUrl,
      'https://ruxbwidezpmyuzuvtpvx.supabase.co',
    );
    expect(SupabaseConfig.publishableKey.startsWith('sb_publishable_'), isTrue);
  });
}
