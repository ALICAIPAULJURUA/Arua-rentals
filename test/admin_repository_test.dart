import 'dart:convert';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/admin/data/admin_repository.dart';
import 'package:arua_rentals/features/auth/data/app_user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _adminId = '5f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _userId = '7f6563bf-1b9f-45bf-94a4-a19161d3810a';
const _requestId = '810ac401-4357-414e-834f-269edb122111';
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

SupabaseClient _makeClient(
  Future<http.Response> Function(http.Request request) handler,
) => SupabaseClient(
  'https://test-project.supabase.co',
  'sb_publishable_test',
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  httpClient: MockClient(handler),
);

Future<void> _signIn(SupabaseClient client) async {
  await client.auth.signInWithPassword(
    email: 'admin@example.test',
    password: 'valid-test-password',
  );
}

void main() {
  test('approves role requests through the protected atomic RPC', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _authResponse(request);
      }
      if (request.url.path.endsWith('/rest/v1/role_requests')) {
        return _jsonResponse(request, [
          {'requested_role': 'landlord', 'status': 'pending'},
        ]);
      }
      if (request.url.path.endsWith('/rpc/review_role_request')) {
        return http.Response('', 204, request: request);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);

    await AdminRepository(client: client)
        .approveRoleRequest(_requestId, RoleRequest.landlord);

    final rpc = requests.last;
    expect(rpc.method, 'POST');
    expect(rpc.url.path, endsWith('/rpc/review_role_request'));
    expect(jsonDecode(rpc.body), {
      'p_request_id': _requestId,
      'p_decision': 'approved',
      'p_rejection_reason': null,
    });
  });

  test('validates rejection reasons and sends reviewed request id', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _authResponse(request);
      }
      if (request.url.path.endsWith('/rpc/review_role_request')) {
        return http.Response('', 204, request: request);
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    final repository = AdminRepository(client: client);

    await expectLater(
      repository.rejectRoleRequest(_requestId, ' '),
      throwsA(isA<AppException>()),
    );
    expect(requests, hasLength(1));
    await repository.rejectRoleRequest(_requestId, '  Missing documents  ');

    expect(jsonDecode(requests.last.body), {
      'p_request_id': _requestId,
      'p_decision': 'rejected',
      'p_rejection_reason': 'Missing documents',
    });
  });

  test(
    'blocks non-admin client operations before making data requests',
    () async {
      final requests = <http.Request>[];
      final client = _makeClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _authResponse(request, admin: false);
        }
        return _jsonResponse(request, <Object>[]);
      });
      addTearDown(client.dispose);
      await _signIn(client);
      requests.clear();

      await expectLater(
        AdminRepository(client: client).getPendingListings(),
        throwsA(isA<AppException>()),
      );

      expect(requests, isEmpty);
    },
  );

  test(
    'does not allow admin role assignment from the Flutter client',
    () async {
      final requests = <http.Request>[];
      final client = _makeClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _authResponse(request);
        }
        return _jsonResponse(request, {'id': _userId});
      });
      addTearDown(client.dispose);
      await _signIn(client);
      requests.clear();

      await expectLater(
        AdminRepository(client: client).updateUserRole(_userId, UserRole.admin),
        throwsA(isA<AppException>()),
      );

      expect(requests, isEmpty);
    },
  );

  test(
    'blocks administrator grants from accounts without the super-admin claim',
    () async {
      final requests = <http.Request>[];
      final client = _makeClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _authResponse(request);
        }
        return _jsonResponse(request, {'enabled': true});
      });
      addTearDown(client.dispose);
      await _signIn(client);
      requests.clear();

      await expectLater(
        AdminRepository(client: client)
            .setUserAdminAccess(_userId, enabled: true),
        throwsA(isA<AppException>()),
      );

      expect(requests, isEmpty);
    },
  );

  test('sends admin grants through the protected Edge Function', () async {
    final requests = <http.Request>[];
    final client = _makeClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/v1/token')) {
        return _authResponse(request, admin: false, superAdmin: true);
      }
      if (request.url.path.endsWith('/functions/v1/manage-admin-access')) {
        return _jsonResponse(request, {
          'enabled': true,
          'targetUserId': _userId,
        });
      }
      return _jsonResponse(request, {
        'message': 'Unexpected request',
      }, status: 404);
    });
    addTearDown(client.dispose);
    await _signIn(client);
    requests.clear();

    await AdminRepository(client: client)
        .setUserAdminAccess(_userId, enabled: true);

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(
      requests.single.url.path,
      endsWith('/functions/v1/manage-admin-access'),
    );
    expect(jsonDecode(requests.single.body), {
      'targetUserId': _userId,
      'enabled': true,
    });
  });

  test(
    'does not delete only a profile without deleting the Auth account',
    () async {
      final requests = <http.Request>[];
      final client = _makeClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/v1/token')) {
          return _authResponse(request);
        }
        return _jsonResponse(request, {'id': _userId});
      });
      addTearDown(client.dispose);
      await _signIn(client);
      requests.clear();

      await expectLater(
        AdminRepository(client: client).deleteUserProfile(_userId),
        throwsA(isA<AppException>()),
      );

      expect(requests, isEmpty);
    },
  );
}

http.Response _authResponse(
  http.Request request, {
  bool admin = true,
  bool superAdmin = false,
}) => _jsonResponse(request, {
  'access_token': _accessToken,
  'refresh_token': 'test-refresh-token',
  'expires_in': 3600,
  'token_type': 'bearer',
  'user': {
    'id': _adminId,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'admin@example.test',
    'app_metadata': {'admin': admin, 'super_admin': superAdmin},
    'user_metadata': <String, dynamic>{},
    'created_at': '2026-01-01T00:00:00.000Z',
  },
});
