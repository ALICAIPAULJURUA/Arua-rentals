import 'dart:convert';

import 'package:arua_rentals/features/listings/data/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

http.Response _jsonResponse(http.Request request, Object body) => http.Response(
  jsonEncode(body),
  200,
  request: request,
  headers: const {'content-type': 'application/json'},
);

void main() {
  test(
    'loads category and area names and active states from Supabase',
    () async {
      final client = SupabaseClient(
        'https://test-project.supabase.co',
        'sb_publishable_test',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          final rows = request.url.path.endsWith('/categories')
              ? [
                  {
                    'slug': 'rentals',
                    'name': 'Rentals',
                    'is_active': true,
                    'sort_order': 0,
                  },
                ]
              : [
                  {
                    'slug': 'oli',
                    'name': 'Oli',
                    'is_active': true,
                    'sort_order': 0,
                  },
                ];
          return _jsonResponse(request, rows);
        }),
      );
      addTearDown(client.dispose);

      final config = await AppConfigRepository(client: client).load();

      expect(config.categories.single.id, 'rentals');
      expect(config.activeCategoryLabels, ['Rentals']);
      expect(config.areas.single.id, 'oli');
      expect(config.activeAreaLabels, ['Oli']);
    },
  );

  test('deactivates removed options and upserts current options', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return _jsonResponse(request, [
            {'id': 'existing-uuid', 'slug': 'old-area'},
          ]);
        }
        return http.Response('', 204, request: request);
      }),
    );
    addTearDown(client.dispose);

    await AppConfigRepository(client: client)
        .saveAreas([const ConfigOption(id: 'oli', label: 'Oli', active: true)]);

    final deactivate = requests.singleWhere(
      (request) => request.method == 'PATCH',
    );
    expect(deactivate.url.queryParameters['id'], 'eq.existing-uuid');
    expect(jsonDecode(deactivate.body), {'is_active': false});
    final upsert = requests.singleWhere((request) => request.method == 'POST');
    expect(jsonDecode(upsert.body), [
      {'slug': 'oli', 'name': 'Oli', 'is_active': true, 'sort_order': 0},
    ]);
    expect(upsert.url.queryParameters['on_conflict'], 'slug');
  });
}
