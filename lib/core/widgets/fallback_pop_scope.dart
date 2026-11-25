import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

class FallbackPopScope extends StatelessWidget {
  const FallbackPopScope({
    required this.fallbackRoute,
    required this.child,
    super.key,
  });

  final String fallbackRoute;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    final canPop = router?.canPop() ?? Navigator.of(context).canPop();
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        context.go(fallbackRoute);
      },
      child: child,
    );
  }
}
