abstract final class SupabaseConfig {
  static const _configuredProjectUrl = String.fromEnvironment('SUPABASE_URL');
  static const _configuredPublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static String get projectUrl => _configuredProjectUrl.trim();
  static String get publishableKey => _configuredPublishableKey.trim();
  static const authRedirectUrl = 'aruacityfinder://auth/callback';

  static void validate() =>
      validateValues(projectUrl: projectUrl, publishableKey: publishableKey);

  static void validateValues({
    required String projectUrl,
    required String publishableKey,
  }) {
    final configuredUrl = projectUrl.trim();
    final configuredKey = publishableKey.trim();
    if (configuredUrl.isEmpty || configuredKey.isEmpty) {
      throw const FormatException(
        'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must be provided '
        'with --dart-define-from-file=supabase.local.json.',
      );
    }

    final uri = Uri.tryParse(configuredUrl);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const {'', '/'}.contains(uri.path)) {
      throw const FormatException(
        'SUPABASE_URL must be the HTTPS project root URL, not a REST API or '
        'other resource URL (for example: https://your-project.supabase.co).',
      );
    }
  }
}
