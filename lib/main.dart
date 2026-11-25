import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/supabase_config.dart';
import 'core/config/supabase_configuration_error_screen.dart';

export 'app.dart' show AruaCityFinderApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    SupabaseConfig.validate();
  } on FormatException catch (error) {
    runApp(SupabaseConfigurationErrorScreen(message: error.message.toString()));
    return;
  }
  await Supabase.initialize(
    url: SupabaseConfig.projectUrl,
    publishableKey: SupabaseConfig.publishableKey,
    authOptions: const FlutterAuthClientOptions(persistSession: true),
  );
  runApp(const ProviderScope(child: AruaCityFinderApp()));
}
