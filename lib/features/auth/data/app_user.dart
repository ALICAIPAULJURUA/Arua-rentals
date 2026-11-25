import '../../../core/errors/app_exception.dart';

enum UserRole { tenant, landlord, provider, admin, superAdmin }

extension UserRoleValue on UserRole {
  String get value => this == UserRole.superAdmin ? 'super_admin' : name;

  String get label => this == UserRole.superAdmin ? 'Super admin' : name;

  static UserRole parse(Object? value) {
    for (final role in UserRole.values) {
      if (role.value == value) return role;
    }
    throw const AppException('The account has an invalid role.');
  }
}

enum RoleRequest { landlord, provider }

class AppUser {
  const AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    required this.role,
    this.roleRequest,
    this.photoUrl,
    this.fcmTokens = const [],
    this.createdAt,
    this.isVerified = false,
    this.hasAdminClaim = false,
    this.hasSuperAdminClaim = false,
    this.accountStatus = 'active',
  });

  final String uid;
  final String name;
  final String email;
  final String phone;
  final UserRole role;
  final RoleRequest? roleRequest;
  final String? photoUrl;
  final List<String> fcmTokens;
  final DateTime? createdAt;
  final bool isVerified;
  final bool hasAdminClaim;
  final bool hasSuperAdminClaim;
  final String accountStatus;

  bool get isActive => accountStatus == 'active';
  bool get canAccessAdmin =>
      (role == UserRole.admin && hasAdminClaim) ||
      (role == UserRole.superAdmin && hasSuperAdminClaim);
  bool get isSuperAdmin => role == UserRole.superAdmin && hasSuperAdminClaim;

  factory AppUser.fromSupabaseRow(
    Map<String, dynamic> data, {
    required String authEmail,
    required bool hasAdminClaim,
    bool hasSuperAdminClaim = false,
    String? requestedRole,
  }) {
    final id = data['id'];
    final name = data['full_name'];
    final email = data['email'];
    final phone = data['phone'];
    final role = data['role'];
    final isVerified = data['is_verified'];
    final accountStatus = data['account_status'];
    final photoUrl = data['avatar_url'];
    final fcmTokens = data['fcm_tokens'];
    final createdAt = data['created_at'];
    if (id is! String ||
        name is! String ||
        (email != null && email is! String) ||
        (phone != null && phone is! String) ||
        role is! String ||
        isVerified is! bool ||
        accountStatus is! String ||
        (photoUrl != null && photoUrl is! String) ||
        fcmTokens is! List ||
        fcmTokens.any((token) => token is! String) ||
        createdAt is! String) {
      throw const AppException('The account profile contains invalid data.');
    }

    final parsedCreatedAt = DateTime.tryParse(createdAt);
    if (parsedCreatedAt == null) {
      throw const AppException('The account profile contains an invalid date.');
    }
    final parsedRole = UserRoleValue.parse(role);
    final parsedRoleRequest =
        parsedRole != UserRole.tenant || requestedRole == null
        ? null
        : RoleRequest.values
              .where((value) => value.name == requestedRole)
              .firstOrNull;
    if (parsedRole == UserRole.tenant &&
        requestedRole != null &&
        parsedRoleRequest == null) {
      throw const AppException('The account role request is invalid.');
    }

    return AppUser(
      uid: id,
      name: name,
      email: email as String? ?? authEmail,
      phone: phone as String? ?? '',
      role: parsedRole,
      roleRequest: parsedRoleRequest,
      photoUrl: photoUrl as String?,
      fcmTokens: List<String>.unmodifiable(fcmTokens.cast<String>()),
      createdAt: parsedCreatedAt,
      isVerified: isVerified,
      hasAdminClaim: hasAdminClaim,
      hasSuperAdminClaim: hasSuperAdminClaim,
      accountStatus: accountStatus,
    );
  }
}
