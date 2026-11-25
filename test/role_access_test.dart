import 'package:arua_rentals/core/router/role_access.dart';
import 'package:arua_rentals/features/auth/data/app_user.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('admin route role resolution', () {
    test('requires both the admin profile role and custom claim', () {
      expect(canAccessAdmin(UserRole.admin, hasAdminClaim: true), isTrue);
      expect(canAccessAdmin(UserRole.admin, hasAdminClaim: false), isFalse);
      expect(canAccessAdmin(UserRole.tenant, hasAdminClaim: true), isFalse);
    });

    test('super admin uses a separate trusted claim and profile role', () {
      expect(
        canAccessAdmin(
          UserRole.superAdmin,
          hasAdminClaim: false,
          hasSuperAdminClaim: true,
        ),
        isTrue,
      );
      expect(
        canAccessAdmin(
          UserRole.superAdmin,
          hasAdminClaim: false,
          hasSuperAdminClaim: false,
        ),
        isFalse,
      );
      expect(
        canAccessAdmin(
          UserRole.admin,
          hasAdminClaim: false,
          hasSuperAdminClaim: true,
        ),
        isFalse,
      );
    });

    test('a profile role without a claim is treated as tenant in the UI', () {
      expect(
        effectiveRoleFor(UserRole.admin, hasAdminClaim: false),
        UserRole.tenant,
      );
      expect(
        effectiveRoleFor(UserRole.admin, hasAdminClaim: true),
        UserRole.admin,
      );
      expect(
        effectiveRoleFor(UserRole.landlord, hasAdminClaim: true),
        UserRole.landlord,
      );
      expect(
        effectiveRoleFor(
          UserRole.superAdmin,
          hasAdminClaim: false,
          hasSuperAdminClaim: true,
        ),
        UserRole.superAdmin,
      );
      expect(
        effectiveRoleFor(
          UserRole.superAdmin,
          hasAdminClaim: false,
          hasSuperAdminClaim: false,
        ),
        UserRole.tenant,
      );
    });
  });

  group('provider workspace access', () {
    test('allows approved listing roles and a claimed super admin', () {
      expect(canManageOwnListings(UserRole.landlord), isTrue);
      expect(canManageOwnListings(UserRole.provider), isTrue);
      expect(
        canManageOwnListings(UserRole.superAdmin, hasSuperAdminClaim: true),
        isTrue,
      );
    });

    test('does not allow privileged profiles without the trusted claim', () {
      expect(
        canManageOwnListings(UserRole.superAdmin, hasSuperAdminClaim: false),
        isFalse,
      );
      expect(canManageOwnListings(UserRole.admin), isFalse);
      expect(canManageOwnListings(UserRole.tenant), isFalse);
    });
  });
}
