import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../features/admin/presentation/admin_dashboard_screen.dart';
import '../../features/auth/data/app_user.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/auth_account_screens.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/reset_password_screen.dart';
import '../../features/listings/presentation/provider_listings_screen.dart';
import '../../features/listings/presentation/public_listings_screen.dart';
import '../../features/listings/presentation/listing_detail_screen.dart';
import '../../features/favorites/presentation/favorites_screen.dart';
import '../../features/chat/presentation/chat_inbox_screen.dart';
import '../../features/chat/presentation/chat_room_screen.dart';
import 'role_access.dart';
import '../theme/app_tokens.dart';
import '../widgets/loading_view.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier();
  ref.listen(supabaseAuthStateProvider, (_, _) => refreshNotifier.refresh());
  ref.listen(authEventProvider, (_, _) => refreshNotifier.refresh());
  ref.listen(currentAppUserProvider, (_, _) => refreshNotifier.refresh());

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final path = state.matchedLocation;
      final isPublicPath =
          path == '/' ||
          (state.pathParameters.containsKey('id') &&
              path.startsWith('/listing/'));
      final isAuthPath = const {
        '/login',
        '/register',
        '/forgot-password',
        '/auth/callback',
      }.contains(path);
      final authState = ref.read(supabaseAuthStateProvider);
      final authEvent = ref.read(authEventProvider).asData?.value;
      final isPasswordRecovery =
          authEvent?.event == supabase.AuthChangeEvent.passwordRecovery;

      if (path == '/reset-password' && isPasswordRecovery) return null;
      if (isPasswordRecovery && path != '/reset-password') {
        return '/reset-password';
      }

      if (authState.isLoading) {
        if (isPublicPath || isAuthPath) return null;
        return path == '/loading'
            ? null
            : _loadingLocation(state.uri.toString());
      }
      if (authState.hasError) {
        return isPublicPath || isAuthPath
            ? null
            : _loginLocation(state.uri.toString());
      }

      final authUser = authState.value;
      if (authUser == null) {
        if (isPublicPath || isAuthPath) return null;
        return _loginLocation(state.uri.toString());
      }

      if (isAuthPath) {
        if (path == '/register' && ref.read(registrationInProgressProvider)) {
          return null;
        }
        return _safeRedirect(state.uri.queryParameters['redirect']) ??
            _landingPath(ref);
      }

      final userState = ref.read(currentAppUserProvider);
      if (userState.isLoading) {
        if (isPublicPath) return null;
        return path == '/loading'
            ? null
            : _loadingLocation(state.uri.toString());
      }
      if (userState.hasError || userState.value == null) {
        if (path == '/admin') return '/access-denied';
        if (isPublicPath) return null;
        return path == '/profile-error' ? null : '/profile-error';
      }

      final user = userState.value!;
      if (!user.isActive) {
        if (isPublicPath || path == '/account-disabled') return null;
        return '/account-disabled';
      }
      if (path == '/account-disabled' ||
          path == '/profile-error' ||
          path == '/reset-password' ||
          path == '/auth/callback') {
        return _landingPath(ref);
      }
      final effectiveRole = effectiveRoleFor(
        user.role,
        hasAdminClaim: user.hasAdminClaim,
        hasSuperAdminClaim: user.hasSuperAdminClaim,
      );
      if (path == '/' &&
          (effectiveRole == UserRole.admin ||
              effectiveRole == UserRole.superAdmin) &&
          state.uri.queryParameters['preview'] != 'true') {
        return '/admin';
      }
      if (isPublicPath) return null;
      if (path == '/home') return '/';
      if (path == '/loading') {
        return _safeRedirect(state.uri.queryParameters['redirect']) ??
            _landingPath(ref);
      }
      if (path == '/') return null;
      if (path == '/provider' &&
          !canManageOwnListings(
            user.role,
            hasSuperAdminClaim: user.hasSuperAdminClaim,
          )) {
        return '/home';
      }
      if (path == '/admin' &&
          !canAccessAdmin(
            user.role,
            hasAdminClaim: user.hasAdminClaim,
            hasSuperAdminClaim: user.hasSuperAdminClaim,
          )) {
        return '/access-denied';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) =>
            _publicPage(state.pageKey, const PublicListingsScreen()),
      ),
      GoRoute(
        path: '/listing/:id',
        pageBuilder: (context, state) => _publicPage(
          state.pageKey,
          ListingDetailScreen(listingId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/loading',
        builder: (context, state) => const Scaffold(body: LoadingView()),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => RegisterScreen(
          requestListingRole:
              state.uri.queryParameters['requestListingRole'] == 'true',
        ),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => const ResetPasswordScreen(),
      ),
      GoRoute(
        path: '/auth/callback',
        builder: (context, state) => const Scaffold(body: LoadingView()),
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const AccountProfileScreen(),
      ),
      GoRoute(
        path: '/account-disabled',
        builder: (context, state) => const AccountDisabledScreen(),
      ),
      GoRoute(
        path: '/profile-error',
        builder: (context, state) => const ProfileUnavailableScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const PublicListingsScreen(),
      ),
      GoRoute(
        path: '/provider',
        builder: (context, state) => const ProviderListingsScreen(),
      ),
      GoRoute(
        path: '/favorites',
        builder: (context, state) => const FavoritesScreen(),
      ),
      GoRoute(
        path: '/chat',
        builder: (context, state) => const ChatInboxScreen(),
      ),
      GoRoute(
        path: '/chat/:roomId',
        builder: (context, state) =>
            ChatRoomScreen(roomId: state.pathParameters['roomId']!),
      ),
      GoRoute(
        path: '/admin',
        builder: (context, state) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: '/access-denied',
        builder: (context, state) => const AccessDeniedScreen(),
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    refreshNotifier.dispose();
  });
  return router;
});

CustomTransitionPage<void> _publicPage(LocalKey key, Widget child) =>
    CustomTransitionPage<void>(
      key: key,
      child: child,
      transitionDuration: AppMotion.pageTransitionDuration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );

String _landingPath(Ref ref) {
  final user = ref.read(currentAppUserProvider).asData?.value;
  return user?.canAccessAdmin == true ? '/admin' : '/';
}

String _loginLocation(String returnPath) =>
    Uri(path: '/login', queryParameters: {'redirect': returnPath}).toString();

String _loadingLocation(String returnPath) =>
    Uri(path: '/loading', queryParameters: {'redirect': returnPath}).toString();

String? _safeRedirect(String? value) {
  if (value == null || !value.startsWith('/') || value.startsWith('//')) {
    return null;
  }
  if (value == '/login' ||
      value.startsWith('/login?') ||
      value == '/register' ||
      value.startsWith('/register?')) {
    return null;
  }
  return value;
}

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}
