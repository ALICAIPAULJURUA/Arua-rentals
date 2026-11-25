import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/arua_areas.dart';
import '../../../core/constants/listing_categories.dart';
import '../../../core/errors/app_exception.dart';

class ConfigOption {
  const ConfigOption({
    required this.id,
    required this.label,
    required this.active,
  });

  final String id;
  final String label;
  final bool active;

  Map<String, dynamic> toMap() => {'id': id, 'label': label, 'active': active};

  factory ConfigOption.fromMap(Map<String, dynamic> data) {
    if (data['id'] is! String ||
        data['label'] is! String ||
        data['active'] is! bool) {
      throw const AppException(
        'The listing configuration contains invalid data.',
      );
    }
    return ConfigOption(
      id: data['id'] as String,
      label: data['label'] as String,
      active: data['active'] as bool,
    );
  }
}

class AppConfig {
  const AppConfig({required this.categories, required this.areas});

  final List<ConfigOption> categories;
  final List<ConfigOption> areas;

  List<String> get activeCategoryLabels => categories
      .where((option) => option.active)
      .map((option) => option.label)
      .toList(growable: false);

  List<String> get activeAreaLabels => areas
      .where((option) => option.active)
      .map((option) => option.label)
      .toList(growable: false);
}

class AppConfigRepository {
  AppConfigRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<AppConfig> load() async {
    try {
      final rows = await Future.wait([
        _client
            .from('categories')
            .select('slug, name, is_active, sort_order')
            .order('sort_order'),
        _client
            .from('areas')
            .select('slug, name, is_active, sort_order')
            .order('sort_order'),
      ]);
      return AppConfig(
        categories: rows[0].isEmpty
            ? _defaults(listingCategories)
            : _parseOptions(rows[0], 'categories'),
        areas: rows[1].isEmpty
            ? _defaults(aruaAreas)
            : _parseOptions(rows[1], 'areas'),
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load listing options');
    }
  }

  Future<void> saveCategories(List<ConfigOption> options) =>
      _save('categories', options);

  Future<void> saveAreas(List<ConfigOption> options) => _save('areas', options);

  Future<void> seedDefaults() async {
    await Future.wait([
      saveCategories(_defaults(listingCategories)),
      saveAreas(_defaults(aruaAreas)),
    ]);
  }

  Future<void> _save(String documentId, List<ConfigOption> options) async {
    _validateOptions(options, documentId);
    try {
      final existing = await _client.from(documentId).select('id, slug');
      final activeSlugs = options.map((option) => option.id).toSet();
      for (final row in existing) {
        if (row['slug'] is String && !activeSlugs.contains(row['slug'])) {
          await _client
              .from(documentId)
              .update({'is_active': false})
              .eq('id', row['id']);
        }
      }
      if (options.isNotEmpty) {
        await _client.from(documentId).upsert([
          for (var index = 0; index < options.length; index++)
            {
              'slug': options[index].id,
              'name': options[index].label.trim(),
              'is_active': options[index].active,
              'sort_order': index,
            },
        ], onConflict: 'slug');
      }
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'save listing options');
    }
  }

  List<ConfigOption> _parseOptions(
    List<Map<String, dynamic>> rows,
    String field,
  ) {
    if (rows.any(
      (row) =>
          row['slug'] is! String ||
          row['name'] is! String ||
          row['is_active'] is! bool ||
          row['sort_order'] is! num,
    )) {
      throw AppException('The $field configuration is invalid.');
    }
    final options = rows
        .map(
          (row) => ConfigOption(
            id: row['slug'] as String,
            label: row['name'] as String,
            active: row['is_active'] as bool,
          ),
        )
        .toList(growable: false);
    _validateOptions(options, field);
    return options;
  }

  void _validateOptions(List<ConfigOption> options, String field) {
    final ids = <String>{};
    for (final option in options) {
      if (option.id.trim().isEmpty ||
          option.label.trim().isEmpty ||
          option.id.length > 80 ||
          option.label.length > 60 ||
          !ids.add(option.id)) {
        throw AppException('The $field configuration contains invalid items.');
      }
    }
  }

  List<ConfigOption> _defaults(List<String> labels) => [
    for (final label in labels)
      ConfigOption(id: _idFor(label), label: label, active: true),
  ];

  String _idFor(String label) => label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  AppException _mapDatabaseError(PostgrestException error, String operation) {
    final message = switch (error.code) {
      '42501' => 'Super administrator access is required to $operation.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}
