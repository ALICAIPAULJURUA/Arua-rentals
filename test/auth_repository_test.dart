import 'dart:convert';

import 'package:arua_rentals/core/errors/app_exception.dart';
import 'package:arua_rentals/features/auth/data/app_user.dart';
import 'package:arua_rentals/features/auth/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const userId = '5f6563bf-1b9f-45bf-94a4-a19161d3810a';
  const email = 'user@example.com';
  const accessToken = 'eyJhbGciOiJub25lIn0.eyJleHAiOjQ3MDAwMDAwMDB9.';
  late SupabaseClient client;
  late AuthRepository repository;
  late Map<String, dynamic> profile;
  late List<Map<String, dynamic>> roleRequests;
  late List<http.Request> requests;
  var authUser = <String, dynamic>{};
  var authErrorResponse = false;

  Map<String, dynamic> userJson() => {
    'id': userId,
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': email,
    'app_metadata': <String, dynamic>{},
    'user_metadata': <String, dynamic>{},
    'created_at': '2026-01-01T00:00:00.000Z',
  };

  http.Response jsonResponse(
    Object body, {
    int statusCode = 200,
    http.Request? request,
  }) => http.Response(
    jsonEncode(body),
    statusCode,
    headers: const {'content-type': 'application/json'},
    request: request,
  );

  setUp(() {
    profile = {
      'id': userId,
      'full_name': 'Arua User',
      'email': email,
      'phone': '+256701234567',
      'avatar_url': null,
      'fcm_tokens': <String>[],
      'role': 'tenant',
      'is_verified': false,
      'account_status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
    };
    roleRequests = [];
    requests = [];
    authUser = userJson();
    authErrorResponse = false;
    client = SupabaseClient(
      'https://test-project.supabase.co',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;

        if (path.endsWith('/auth/v1/signup') ||
            path.endsWith('/auth/v1/token')) {
          if (authErrorResponse) {
            return jsonResponse(
              {
                'code': 'invalid_credentials',
                'error_code': 'invalid_credentials',
                'msg': 'Invalid login credentials',
              },
              statusCode: 400,
              request: request,
            );
          }
          if (path.endsWith('/signup')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            authUser = {
              ...userJson(),
              'user_metadata': body['data'] as Map<String, dynamic>,
            };
          }
          return jsonResponse({
            ...authUser,
            'access_token': accessToken,
            'refresh_token': 'test-refresh-token',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': authUser,
          }, request: request);
        }
        if (path.endsWith('/auth/v1/logout')) {
          return http.Response('', 204, request: request);
        }
        if (path.endsWith('/auth/v1/recover')) {
          return http.Response('', 200, request: request);
        }
        if (path.endsWith('/auth/v1/user') && request.method == 'PUT') {
          return jsonResponse(authUser, request: request);
        }
        if (path.endsWith('/rest/v1/profiles')) {
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            profile = {...profile, ...body};
            return jsonResponse({'id': userId}, request: request);
          }
          return jsonResponse([profile], request: request);
        }
        if (path.endsWith('/rest/v1/role_requests')) {
          if (request.method == 'POST') {
            roleRequests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('', 201, request: request);
          }
          return jsonResponse(roleRequests, request: request);
        }
        return jsonResponse(
          {'message': 'Unexpected test request'},
          statusCode: 404,
          request: request,
        );
      }),
    );
    repository = AuthRepository(client: client);
  });

  tearDown(() async {
    await client.dispose();
  });

  test(
    'registration links profile to auth UUID and only submits a role request',
    () async {
      final result = await repository.register(
        email: email,
        password: 'valid-test-password',
        name: 'Arua User',
        phone: '+256701234567',
        roleRequest: RoleRequest.provider,
      );

      expect(result.requiresEmailConfirmation, isFalse);
      expect(result.user?.uid, userId);
      expect(result.user?.role, UserRole.tenant);
      expect(result.user?.roleRequest, RoleRequest.provider);
      expect(roleRequests, hasLength(1));
      expect(roleRequests.single['user_id'], userId);
      expect(roleRequests.single['requested_role'], 'provider');
      expect(profile['role'], 'tenant');
      expect(profile.containsKey('role'), isTrue);
      expect(
        requests
            .firstWhere((request) => request.url.path.endsWith('/signup'))
            .body,
        isNot(contains('"role"')),
      );
    },
  );

  test(
    'login, profile update, password recovery, and logout use Supabase',
    () async {
      await repository.login(email: email, password: 'valid-test-password');
      expect(client.auth.currentUser?.id, userId);

      final updated = await repository.updateProfile(
        name: 'Updated User',
        phone: '0701 234 568',
      );
      expect(updated.name, 'Updated User');
      expect(updated.phone, '+256701234568');
      expect(profile['role'], 'tenant');
      expect(profile['account_status'], 'active');

      await repository.sendPasswordResetEmail(email);
      await repository.updatePassword('another-valid-password');
      await repository.logout();

      expect(client.auth.currentUser, isNull);
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/auth/v1/recover') &&
              request.method == 'POST',
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) =>
              request.url.path.endsWith('/auth/v1/logout') &&
              request.method == 'POST',
        ),
        isTrue,
      );
    },
  );

  test('refreshing server role claims reloads the same account', () async {
    final seenSuperAdminClaim = <bool>[];
    final subscription = repository.authStateChanges.listen((user) {
      if (user != null) {
        seenSuperAdminClaim.add(user.appMetadata['super_admin'] == true);
      }
    });
    addTearDown(subscription.cancel);

    await repository.login(email: email, password: 'valid-test-password');
    authUser = {
      ...authUser,
      'app_metadata': {'super_admin': true},
    };
    await client.auth.refreshSession();
    await Future<void>.delayed(Duration.zero);

    expect(seenSuperAdminClaim, contains(true));
  });

  test(
    'does not load a pending tenant request for a super admin profile',
    () async {
      profile['role'] = 'super_admin';
      roleRequests.add({
        'id': 'old-request',
        'user_id': userId,
        'requested_role': 'provider',
        'status': 'pending',
      });

      final user = await repository.loadUser(
        userId,
        hasSuperAdminClaim: true,
        authEmail: email,
      );

      expect(user?.role, UserRole.superAdmin);
      expect(user?.roleRequest, isNull);
      expect(
        requests.any(
          (request) => request.url.path.endsWith('/rest/v1/role_requests'),
        ),
        isFalse,
      );
    },
  );

  test(
    'tenant role request creates a pending request without changing role',
    () async {
      await repository.login(email: email, password: 'valid-test-password');

      await repository.requestRole(
        profile: const AppUser(
          uid: userId,
          name: 'Arua User',
          email: email,
          phone: '+256701234567',
          role: UserRole.tenant,
        ),
        requestedRole: RoleRequest.provider,
      );

      expect(roleRequests, hasLength(1));
      expect(roleRequests.single['user_id'], userId);
      expect(roleRequests.single['requested_role'], 'provider');
      expect(roleRequests.single['status'], 'pending');
      expect(profile['role'], 'tenant');
    },
  );

  test('tenant cannot submit a second pending role request', () async {
    await repository.login(email: email, password: 'valid-test-password');
    roleRequests.add({
      'id': 'existing-request',
      'user_id': userId,
      'requested_role': 'landlord',
      'status': 'pending',
    });

    await expectLater(
      repository.requestRole(
        profile: const AppUser(
          uid: userId,
          name: 'Arua User',
          email: email,
          phone: '+256701234567',
          role: UserRole.tenant,
        ),
        requestedRole: RoleRequest.provider,
      ),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          'You already have a pending role request.',
        ),
      ),
    );
    expect(
      requests.any(
        (request) =>
            request.url.path.endsWith('/rest/v1/role_requests') &&
            request.method == 'POST',
      ),
      isFalse,
    );
  });

  test('invalid credentials return an actionable error', () async {
    authErrorResponse = true;

    await expectLater(
      repository.login(email: email, password: 'incorrect'),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          'The email or password is incorrect.',
        ),
      ),
    );
  });
}
