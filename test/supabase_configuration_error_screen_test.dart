import 'package:arua_rentals/core/config/supabase_configuration_error_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('missing Supabase configuration shows the run command', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SupabaseConfigurationErrorScreen(
        message: 'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are required.',
      ),
    );

    expect(find.text('Supabase configuration is required'), findsOneWidget);
    expect(
      find.text(
        'flutter run -d chrome --dart-define-from-file=supabase.local.json',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
