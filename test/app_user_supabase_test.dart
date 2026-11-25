import 'package:arua_rentals/core/router/role_access.dart';
import 'package:arua_rentals/features/auth/data/app_user.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> profile({
    String role = 'tenant',
    String accountStatus = 'active',
  }) => {
    'id': '5f6563bf-1b9f-45bf-94a4-a19161d3810a',
    'full_name': 'Arua User',
    'email': 'user@example.com',
    'phone': '+256701234567',
    'avatar_url': null,
    'fcm_tokens': <String>[],
    'role': role,
    'is_verified': false,
    'account_status': accountStatus,
    'created_at': '2026-01-01T00:00:00.000Z',
  };

  test('maps Supabase profile and pending role request without privilege', () {
    final user = AppUser.fromSupabaseRow(
      profile(),
      authEmail: 'user@example.com',
      hasAdminClaim: false,
      requestedRole: 'provider',
    );

    expect(user.uid, '5f6563bf-1b9f-45bf-94a4-a19161d3810a');
    expect(user.role, UserRole.tenant);
    expect(user.roleRequest, RoleRequest.provider);
    expect(user.isActive, isTrue);
    expect(
      canAccessAdmin(user.role, hasAdminClaim: user.hasAdminClaim),
      isFalse,
    );
  });

  test(
    'does not trust an administrator profile role without the server claim',
    () {
      final user = AppUser.fromSupabaseRow(
        profile(role: 'admin'),
        authEmail: 'admin@example.com',
        hasAdminClaim: false,
      );

      expect(
        effectiveRoleFor(user.role, hasAdminClaim: user.hasAdminClaim),
        UserRole.tenant,
      );
      expect(
        canAccessAdmin(user.role, hasAdminClaim: user.hasAdminClaim),
        isFalse,
      );
    },
  );

  test('marks non-active profile states as unavailable', () {
    final user = AppUser.fromSupabaseRow(
      profile(accountStatus: 'suspended'),
      authEmail: 'user@example.com',
      hasAdminClaim: false,
    );

    expect(user.isActive, isFalse);
  });

  test('parses a super_admin profile only with the trusted claim', () {
    final user = AppUser.fromSupabaseRow(
      profile(role: 'super_admin'),
      authEmail: 'super@example.com',
      hasAdminClaim: false,
      hasSuperAdminClaim: true,
    );

    expect(user.role, UserRole.superAdmin);
    expect(user.isSuperAdmin, isTrue);
    expect(user.canAccessAdmin, isTrue);
    expect(UserRoleValue.parse('super_admin'), UserRole.superAdmin);
    expect(UserRole.superAdmin.value, 'super_admin');
  });

  test('does not trust a super_admin profile without the trusted claim', () {
    final user = AppUser.fromSupabaseRow(
      profile(role: 'super_admin'),
      authEmail: 'super@example.com',
      hasAdminClaim: false,
    );

    expect(user.canAccessAdmin, isFalse);
    expect(user.isSuperAdmin, isFalse);
  });

  test('ignores stale role requests after privileged role assignment', () {
    final user = AppUser.fromSupabaseRow(
      profile(role: 'super_admin'),
      authEmail: 'super@example.com',
      hasAdminClaim: false,
      hasSuperAdminClaim: true,
      requestedRole: 'provider',
    );

    expect(user.role, UserRole.superAdmin);
    expect(user.roleRequest, isNull);
  });
}
