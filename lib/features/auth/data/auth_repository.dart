import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/config/supabase_config.dart';
import '../../../core/utils/phone_normalizer.dart';
import 'app_user.dart';

class AuthRepository {
  AuthRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Stream<User?> get authStateChanges => _client.auth.onAuthStateChange
      .map((state) => state.session?.user)
      .distinct(
        (previous, next) =>
            previous?.id == next?.id &&
            previous?.appMetadata['admin'] == next?.appMetadata['admin'] &&
            previous?.appMetadata['super_admin'] ==
                next?.appMetadata['super_admin'],
      );

  Stream<AuthState> get authEvents => _client.auth.onAuthStateChange;

  User? get currentUser => _client.auth.currentUser;

  Future<AppUser?> loadUser(
    String uid, {
    bool hasAdminClaim = false,
    bool hasSuperAdminClaim = false,
    String? authEmail,
  }) async {
    try {
      final row = await _client
          .from('profiles')
          .select()
          .eq('id', uid)
          .maybeSingle();
      if (row == null) return null;

      final pendingRequest = row['role'] == UserRole.tenant.value
          ? await _client
                .from('role_requests')
                .select('requested_role')
                .eq('user_id', uid)
                .eq('status', 'pending')
                .order('created_at', ascending: false)
                .limit(1)
                .maybeSingle()
          : null;
      return AppUser.fromSupabaseRow(
        row,
        authEmail: authEmail ?? '',
        hasAdminClaim: hasAdminClaim,
        hasSuperAdminClaim: hasSuperAdminClaim,
        requestedRole: pendingRequest?['requested_role'] as String?,
      );
    } on PostgrestException catch (error) {
      throw _mapPostgrestException(error, 'load the account profile');
    }
  }

  Future<AppUser> loadOrCreateUser(User authUser) async {
    final hasAdminClaim = authUser.appMetadata['admin'] == true;
    final hasSuperAdminClaim = authUser.appMetadata['super_admin'] == true;
    final existing = await loadUser(
      authUser.id,
      hasAdminClaim: hasAdminClaim,
      hasSuperAdminClaim: hasSuperAdminClaim,
      authEmail: authUser.email,
    );
    if (existing == null) {
      throw const AppException(
        'Your profile could not be found. Please contact support.',
      );
    }
    await _ensureRequestedRole(authUser, existing);
    return await loadUser(
          authUser.id,
          hasAdminClaim: hasAdminClaim,
          hasSuperAdminClaim: hasSuperAdminClaim,
          authEmail: authUser.email,
        ) ??
        (throw const AppException('The account profile could not be loaded.'));
  }

  Future<void> _ensureRequestedRole(User authUser, AppUser profile) async {
    if (!profile.isActive || profile.role != UserRole.tenant) return;
    final requestedRole = authUser.userMetadata?['requested_role'];
    final roleRequest = RoleRequest.values
        .where((value) => value.name == requestedRole)
        .firstOrNull;
    if (roleRequest == null || profile.roleRequest != null) return;

    try {
      final existingPending = await _client
          .from('role_requests')
          .select('id')
          .eq('user_id', authUser.id)
          .eq('status', 'pending')
          .limit(1)
          .maybeSingle();
      if (existingPending != null) return;

      await _client.from('role_requests').insert({
        'user_id': authUser.id,
        'requested_role': roleRequest.name,
        'status': 'pending',
        'name': profile.name,
        'email': profile.email,
        'phone': profile.phone,
      });
    } on PostgrestException catch (error) {
      if (error.code == '23505') return;
      throw _mapPostgrestException(error, 'submit the role request');
    }
  }

  Future<RegistrationResult> register({
    required String email,
    required String password,
    required String name,
    required String phone,
    RoleRequest? roleRequest,
  }) async {
    late final AuthResponse response;
    try {
      response = await _client.auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: kIsWeb ? null : SupabaseConfig.authRedirectUrl,
        data: {
          'full_name': name.trim(),
          'phone': phone,
          if (roleRequest != null) 'requested_role': roleRequest.name,
        },
      );
      if (response.user == null) {
        throw const AppException('Account creation did not return a user.');
      }
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
    final authUser = response.user!;
    if (response.session == null) {
      return const RegistrationResult(requiresEmailConfirmation: true);
    }

    return RegistrationResult(
      user: await loadOrCreateUser(authUser),
      requiresEmailConfirmation: false,
    );
  }

  Future<void> login({required String email, required String password}) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
  }

  Future<void> logout() async {
    try {
      await _client.auth.signOut();
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
  }

  Future<void> requestRole({
    required AppUser profile,
    required RoleRequest requestedRole,
  }) async {
    final authUser = _client.auth.currentUser;
    if (authUser == null) {
      throw const AppException('Sign in before requesting listing access.');
    }
    if (profile.uid != authUser.id || profile.role != UserRole.tenant) {
      throw const AppException(
        'Only your tenant account can request listing access.',
      );
    }
    if (profile.roleRequest != null) {
      throw const AppException('You already have a pending role request.');
    }

    try {
      final pendingRequest = await _client
          .from('role_requests')
          .select('id')
          .eq('user_id', authUser.id)
          .eq('status', 'pending')
          .limit(1)
          .maybeSingle();
      if (pendingRequest != null) {
        throw const AppException('You already have a pending role request.');
      }

      await _client.from('role_requests').insert({
        'user_id': authUser.id,
        'requested_role': requestedRole.name,
        'status': 'pending',
        'name': profile.name,
        'email': profile.email,
        'phone': profile.phone,
      });
    } on PostgrestException catch (error) {
      throw _mapPostgrestException(error, 'submit the role request');
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? null : SupabaseConfig.authRedirectUrl,
      );
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
  }

  Future<void> updatePassword(String password) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: password));
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
  }

  Future<void> refreshSession() async {
    try {
      await _client.auth.refreshSession();
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    }
  }

  Future<AppUser> updateProfile({
    required String name,
    required String phone,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('Sign in before updating your profile.');
    }
    final normalizedPhone = normalizeUgandanPhone(phone);
    if (name.trim().isEmpty || normalizedPhone == null) {
      throw const AppException(
        'Enter a name and a valid Ugandan phone number.',
      );
    }
    try {
      await _client
          .from('profiles')
          .update({'full_name': name.trim(), 'phone': normalizedPhone})
          .eq('id', user.id)
          .select('id')
          .single();
    } on PostgrestException catch (error) {
      throw _mapPostgrestException(error, 'update the account profile');
    }
    return await loadUser(
          user.id,
          hasAdminClaim: user.appMetadata['admin'] == true,
          hasSuperAdminClaim: user.appMetadata['super_admin'] == true,
          authEmail: user.email,
        ) ??
        (throw const AppException('The account profile could not be loaded.'));
  }

  AppException _mapAuthException(AuthException error) {
    final message = switch (error.code) {
      'invalid_credentials' => 'The email or password is incorrect.',
      'email_not_confirmed' => 'Confirm your email address before signing in.',
      'user_already_exists' => 'An account already uses this email address.',
      'weak_password' => 'Choose a stronger password.',
      'over_request_rate_limit' =>
        'Too many attempts. Wait a little and try again.',
      _ when error.statusCode == '429' =>
        'Too many attempts. Wait a little and try again.',
      _ => 'Authentication failed. Check your connection and try again.',
    };
    return AppException(message, code: error.code ?? error.statusCode);
  }

  AppException _mapPostgrestException(
    PostgrestException error,
    String operation,
  ) {
    final message = switch (error.code) {
      '42501' => 'You are not allowed to $operation.',
      '23505' => 'This account already has a pending role request.',
      _ => 'Unable to $operation. Please try again.',
    };
    return AppException(message, code: error.code);
  }
}

class RegistrationResult {
  const RegistrationResult({
    this.user,
    required this.requiresEmailConfirmation,
  });

  final AppUser? user;
  final bool requiresEmailConfirmation;
}
