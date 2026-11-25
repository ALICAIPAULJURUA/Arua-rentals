import '../../features/auth/data/app_user.dart';

UserRole effectiveRoleFor(
  UserRole profileRole, {
  required bool hasAdminClaim,
  bool hasSuperAdminClaim = false,
}) {
  if (profileRole == UserRole.admin && !hasAdminClaim) {
    return UserRole.tenant;
  }
  if (profileRole == UserRole.superAdmin && !hasSuperAdminClaim) {
    return UserRole.tenant;
  }
  return profileRole;
}

bool canAccessAdmin(
  UserRole profileRole, {
  required bool hasAdminClaim,
  bool hasSuperAdminClaim = false,
}) =>
    (profileRole == UserRole.admin && hasAdminClaim) ||
    (profileRole == UserRole.superAdmin && hasSuperAdminClaim);

bool canManageOwnListings(
  UserRole profileRole, {
  bool hasSuperAdminClaim = false,
}) =>
    profileRole == UserRole.landlord ||
    profileRole == UserRole.provider ||
    (profileRole == UserRole.superAdmin && hasSuperAdminClaim);
