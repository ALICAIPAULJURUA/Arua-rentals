import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SupabaseConfigurationErrorScreen extends StatelessWidget {
  const SupabaseConfigurationErrorScreen({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Arua City Finder',
    theme: AppTheme.light,
    home: Scaffold(
      appBar: AppBar(title: const Text('Arua City Finder')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Supabase configuration is required',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                const SelectableText(
                  'flutter run -d chrome --dart-define-from-file=supabase.local.json',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Create the ignored supabase.local.json file from your '
                  'Supabase project URL and publishable key.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
