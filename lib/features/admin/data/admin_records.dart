import '../../../core/errors/app_exception.dart';
import '../../auth/data/app_user.dart';

class AdminCursor {
  const AdminCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;
}

class AdminPage<T> {
  const AdminPage({required this.items, required this.lastDocument});

  final List<T> items;
  final AdminCursor? lastDocument;
}

class AdminDashboardStats {
  const AdminDashboardStats({
    required this.totalUsers,
    required this.pendingRoleRequests,
    required this.pendingListings,
    required this.approvedListings,
    required this.rejectedListings,
  });

  final int totalUsers;
  final int pendingRoleRequests;
  final int pendingListings;
  final int approvedListings;
  final int rejectedListings;
}

class AdminRoleRequest {
  const AdminRoleRequest({
    required this.id,
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    required this.requestedRole,
    required this.createdAt,
  });

  final String id;
  final String uid;
  final String name;
  final String email;
  final String phone;
  final RoleRequest requestedRole;
  final DateTime? createdAt;

  factory AdminRoleRequest.fromSupabaseRow(Map<String, dynamic> data) {
    final id = data['id'];
    final uid = data['user_id'];
    final name = data['name'];
    final email = data['email'];
    final phone = data['phone'];
    final requestedRole = RoleRequest.values
        .where((role) => role.name == data['requested_role'])
        .firstOrNull;
    if (id is! String ||
        uid is! String ||
        name is! String ||
        email is! String ||
        phone is! String ||
        requestedRole == null) {
      throw const AppException('A role request contains invalid data.');
    }
    return AdminRoleRequest(
      id: id,
      uid: uid,
      name: name,
      email: email,
      phone: phone,
      requestedRole: requestedRole,
      createdAt: _parseDate(data['created_at']),
    );
  }
}

class AdminUserRecord {
  const AdminUserRecord({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone,
    required this.role,
    required this.isVerified,
    required this.accountStatus,
    this.createdAt,
  });

  final String uid;
  final String name;
  final String email;
  final String phone;
  final UserRole role;
  final bool isVerified;
  final String accountStatus;
  final DateTime? createdAt;

  factory AdminUserRecord.fromSupabaseRow(Map<String, dynamic> data) {
    final uid = data['id'];
    final name = data['full_name'];
    final email = data['email'];
    final phone = data['phone'];
    final rawRole = data['role'];
    UserRole? role;
    try {
      role = UserRoleValue.parse(rawRole);
    } on AppException {
      role = null;
    }
    final isVerified = data['is_verified'];
    final accountStatus = data['account_status'];
    if (uid is! String ||
        name is! String ||
        (email != null && email is! String) ||
        (phone != null && phone is! String) ||
        role == null ||
        isVerified is! bool ||
        (accountStatus != null && accountStatus is! String)) {
      throw const AppException('A user profile contains invalid data.');
    }
    return AdminUserRecord(
      uid: uid,
      name: name,
      email: email as String? ?? '',
      phone: phone as String? ?? '',
      role: role,
      isVerified: isVerified,
      accountStatus: accountStatus as String? ?? 'active',
      createdAt: _parseDate(data['created_at']),
    );
  }
}

class AdminListingRecord {
  const AdminListingRecord({
    required this.id,
    required this.title,
    required this.ownerName,
    required this.area,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String ownerName;
  final String area;
  final DateTime? createdAt;

  factory AdminListingRecord.fromSupabaseRow(Map<String, dynamic> data) {
    final id = data['id'];
    final title = data['title'];
    final ownerName = data['owner_name'];
    final areaRow = data['areas'];
    final area = areaRow is Map ? areaRow['name'] : null;
    if (id is! String ||
        title is! String ||
        (ownerName != null && ownerName is! String) ||
        (area != null && area is! String)) {
      throw const AppException('A listing contains invalid moderation data.');
    }
    return AdminListingRecord(
      id: id,
      title: title,
      ownerName: ownerName as String? ?? '',
      area: area as String? ?? '',
      createdAt: _parseDate(data['created_at']),
    );
  }
}

DateTime? _parseDate(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
