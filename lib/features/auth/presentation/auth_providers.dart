import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../../core/router/role_access.dart';
import '../data/app_user.dart';
import '../data/auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(),
);

final supabaseAuthStateProvider = StreamProvider<supabase.User?>(
  (ref) => ref.watch(authRepositoryProvider).authStateChanges,
);

final authEventProvider = StreamProvider<supabase.AuthState>(
  (ref) => ref.watch(authRepositoryProvider).authEvents,
);

final currentAppUserProvider = FutureProvider<AppUser?>((ref) async {
  final authUser = await ref.watch(supabaseAuthStateProvider.future);
  if (authUser == null) return null;
  return ref.watch(authRepositoryProvider).loadOrCreateUser(authUser);
});

final currentUserRoleProvider = Provider<AsyncValue<UserRole?>>(
  (ref) => ref.watch(currentAppUserProvider).whenData((user) {
    if (user == null) return null;
    return effectiveRoleFor(
      user.role,
      hasAdminClaim: user.hasAdminClaim,
      hasSuperAdminClaim: user.hasSuperAdminClaim,
    );
  }),
);

final registrationInProgressProvider =
    NotifierProvider<RegistrationFlowNotifier, bool>(
      RegistrationFlowNotifier.new,
    );

class RegistrationFlowNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setInProgress(bool value) {
    state = value;
  }
}
