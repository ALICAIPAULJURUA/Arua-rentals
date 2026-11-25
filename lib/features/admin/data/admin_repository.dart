import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/phone_normalizer.dart';
import '../../auth/data/app_user.dart';
import 'admin_records.dart';

class AdminRepository {
  static const _userSelection =
      'id, full_name, email, phone, role, is_verified, account_status, created_at';
  static const _requestSelection =
      'id, user_id, name, email, phone, requested_role, created_at';
  static const _listingSelection =
      'id, title, owner_name, areas(name), created_at';
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  AdminRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<AdminPage<AdminRoleRequest>> getPendingRoleRequests({
    int limit = 20,
    AdminCursor? startAfter,
  }) async {
    _requireAdmin();
    _validatePage(limit, startAfter);
    try {
      var query = _client
          .from('role_requests')
          .select(_requestSelection)
          .eq('status', 'pending');
      query = _applyCursor(query, startAfter);
      final rows = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit);
      return AdminPage(
        items: rows.map(AdminRoleRequest.fromSupabaseRow).toList(),
        lastDocument: _lastCursor(rows),
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load pending role requests');
    }
  }

  Future<AdminPage<AdminListingRecord>> getPendingListings({
    int limit = 20,
    AdminCursor? startAfter,
  }) async {
    _requireAdmin();
    _validatePage(limit, startAfter);
    try {
      var query = _client
          .from('listings')
          .select(_listingSelection)
          .eq('status', 'pending');
      query = _applyCursor(query, startAfter);
      final rows = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit);
      return AdminPage(
        items: rows.map(AdminListingRecord.fromSupabaseRow).toList(),
        lastDocument: _lastCursor(rows),
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load pending listings');
    }
  }

  Future<AdminDashboardStats> getDashboardStats() async {
    _requireAdmin();
    try {
      final counts = await Future.wait<int>([
        _client.from('profiles').count(),
        _client.from('role_requests').count().eq('status', 'pending'),
        _client.from('listings').count().eq('status', 'pending'),
        _client.from('listings').count().eq('status', 'approved'),
        _client.from('listings').count().eq('status', 'rejected'),
      ]);
      return AdminDashboardStats(
        totalUsers: counts[0],
        pendingRoleRequests: counts[1],
        pendingListings: counts[2],
        approvedListings: counts[3],
        rejectedListings: counts[4],
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'load the dashboard');
    }
  }

  Future<AdminPage<AdminUserRecord>> listUsers({
    int limit = 20,
    AdminCursor? startAfter,
  }) => _queryUsers(limit: limit, startAfter: startAfter);

  Future<AdminPage<AdminUserRecord>> searchUsers(
    String searchTerm, {
    int limit = 20,
    AdminCursor? startAfter,
  }) {
    final term = searchTerm.trim();
    if (term.isEmpty) return listUsers(limit: limit, startAfter: startAfter);
    return _queryUsers(limit: limit, startAfter: startAfter, searchTerm: term);
  }

  Future<AdminPage<AdminUserRecord>> _queryUsers({
    required int limit,
    AdminCursor? startAfter,
    String? searchTerm,
  }) async {
    _requireAdmin();
    _validatePage(limit, startAfter);
    try {
      var query = _client.from('profiles').select(_userSelection);
      if (searchTerm != null) {
        final escaped = searchTerm
            .replaceAll(r'\', r'\\')
            .replaceAll('%', r'\%')
            .replaceAll('_', r'\_');
        final field = searchTerm.contains('@') ? 'email' : 'full_name';
        query = query.ilike(field, '%$escaped%');
      }
      query = _applyCursor(query, startAfter);
      final rows = await query
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(limit);
      return AdminPage(
        items: rows.map(AdminUserRecord.fromSupabaseRow).toList(),
        lastDocument: _lastCursor(rows),
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'search account profiles');
    }
  }

  Future<void> approveRoleRequest(String requestId, RoleRequest role) async {
    _requireAdmin();
    _requireUuid(requestId, 'role request');
    try {
      final row = await _client
          .from('role_requests')
          .select('requested_role,status')
          .eq('id', requestId)
          .maybeSingle();
      if (row == null ||
          row['status'] != 'pending' ||
          row['requested_role'] != role.name) {
        throw const AppException(
          'This role request is no longer pending or has changed.',
        );
      }
      await _client.rpc(
        'review_role_request',
        params: {
          'p_request_id': requestId,
          'p_decision': 'approved',
          'p_rejection_reason': null,
        },
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'approve this role request');
    }
  }

  Future<void> rejectRoleRequest(String requestId, String reason) async {
    _requireAdmin();
    _requireUuid(requestId, 'role request');
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty || cleanReason.length > 500) {
      throw const AppException(
        'Enter a rejection reason of 1 to 500 characters.',
      );
    }
    try {
      await _client.rpc(
        'review_role_request',
        params: {
          'p_request_id': requestId,
          'p_decision': 'rejected',
          'p_rejection_reason': cleanReason,
        },
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'reject this role request');
    }
  }

  Future<void> updateUserRole(String uid, UserRole role) async {
    _requireAdmin();
    _requireUuid(uid, 'user');
    if (role == UserRole.admin || role == UserRole.superAdmin) {
      throw const AppException(
        'Administrator access must be managed by a super administrator.',
      );
    }
    try {
      await _client
          .from('profiles')
          .update({'role': role.value})
          .eq('id', uid)
          .select('id')
          .single();
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'update the account role');
    }
  }

  Future<void> setUserAdminAccess(String uid, {required bool enabled}) async {
    _requireSuperAdmin();
    _requireUuid(uid, 'user');
    final caller = _client.auth.currentUser!;
    if (uid == caller.id) {
      throw const AppException(
        'You cannot change your own administrator access.',
      );
    }
    try {
      await _client.functions.invoke(
        'manage-admin-access',
        body: {'targetUserId': uid, 'enabled': enabled},
      );
    } on FunctionException catch (error) {
      throw AppException(
        enabled
            ? 'Unable to grant administrator access.'
            : 'Unable to revoke administrator access.',
        code: error.status.toString(),
      );
    }
  }

  Future<void> setUserVerified(String uid, bool isVerified) async {
    _requireAdmin();
    _requireUuid(uid, 'user');
    try {
      await _client
          .from('profiles')
          .update({'is_verified': isVerified})
          .eq('id', uid)
          .select('id')
          .single();
      await _client
          .from('listings')
          .update({'owner_verified': isVerified})
          .eq('owner_id', uid);
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'update account verification');
    }
  }

  Future<void> updateUserProfile({
    required String uid,
    required String name,
    required String phone,
  }) async {
    _requireAdmin();
    _requireUuid(uid, 'user');
    final cleanName = name.trim();
    final cleanPhone = phone.trim().isEmpty
        ? null
        : normalizeUgandanPhone(phone);
    if (cleanName.isEmpty ||
        cleanName.length > 100 ||
        (phone.trim().isNotEmpty && cleanPhone == null)) {
      throw const AppException('Enter a valid name and Ugandan phone number.');
    }
    try {
      await _client
          .from('profiles')
          .update({'full_name': cleanName, 'phone': cleanPhone})
          .eq('id', uid)
          .select('id')
          .single();
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'update the account profile');
    }
  }

  Future<void> deleteUserProfile(String uid) async {
    _requireAdmin();
    _requireUuid(uid, 'user');
    throw const AppException(
      'Deleting an Auth account requires a trusted server-side admin endpoint. No profile-only delete was performed.',
    );
  }

  Future<void> approveListing(String listingId) async {
    _requireAdmin();
    _requireUuid(listingId, 'listing');
    try {
      await _client.rpc(
        'review_listing',
        params: {
          'p_listing_id': listingId,
          'p_status': 'approved',
          'p_rejection_reason': null,
        },
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'approve this listing');
    }
  }

  Future<void> rejectListing(String listingId, String reason) async {
    _requireAdmin();
    _requireUuid(listingId, 'listing');
    final cleanReason = reason.trim();
    if (cleanReason.isEmpty || cleanReason.length > 500) {
      throw const AppException(
        'Enter a rejection reason of 1 to 500 characters.',
      );
    }
    try {
      await _client.rpc(
        'review_listing',
        params: {
          'p_listing_id': listingId,
          'p_status': 'rejected',
          'p_rejection_reason': cleanReason,
        },
      );
    } on PostgrestException catch (error) {
      throw _mapDatabaseError(error, 'reject this listing');
    }
  }

  PostgrestFilterBuilder<List<Map<String, dynamic>>> _applyCursor(
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query,
    AdminCursor? cursor,
  ) {
    if (cursor == null) return query;
    final timestamp = cursor.createdAt.toUtc().toIso8601String();
    return query.or(
      'created_at.lt.$timestamp,'
      'and(created_at.eq.$timestamp,id.lt.${cursor.id})',
    );
  }

  AdminCursor? _lastCursor(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return null;
    final id = rows.last['id'];
    final createdAt = rows.last['created_at'];
    final parsed = createdAt is String ? DateTime.tryParse(createdAt) : null;
    if (id is! String || parsed == null) {
      throw const AppException('An admin record contains an invalid cursor.');
    }
    return AdminCursor(createdAt: parsed, id: id);
  }

  void _validatePage(int limit, AdminCursor? cursor) {
    if (limit < 1 || limit > 100) {
      throw const AppException('Page size must be between 1 and 100.');
    }
    if (cursor != null) _requireUuid(cursor.id, 'cursor');
  }

  void _requireAdmin() {
    final user = _client.auth.currentUser;
    if (user == null ||
        (user.appMetadata['admin'] != true &&
            user.appMetadata['super_admin'] != true)) {
      throw const AppException('Administrator access is required.');
    }
  }

  void _requireSuperAdmin() {
    final user = _client.auth.currentUser;
    if (user == null || user.appMetadata['super_admin'] != true) {
      throw const AppException('Super administrator access is required.');
    }
  }

  void _requireUuid(String value, String kind) {
    if (!_uuidPattern.hasMatch(value)) {
      throw AppException('The $kind identifier is invalid.');
    }
  }

  AppException _mapDatabaseError(PostgrestException error, String operation) {
    final message = switch (error.code) {
      '42501' => 'Administrator access is required to $operation.',
      'P0001' => error.message,
      '23503' => 'The referenced account or listing no longer exists.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}
