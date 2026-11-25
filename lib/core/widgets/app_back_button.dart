import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppBackButton extends StatelessWidget {
  const AppBackButton({
    this.fallbackRoute = '/',
    this.color,
    super.key,
  });

  final String fallbackRoute;
  final Color? color;

  void _handleBack(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router?.canPop() ?? Navigator.of(context).canPop()) {
      context.pop();
      return;
    }
    context.go(fallbackRoute);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: Icon(Icons.arrow_back, color: color),
      onPressed: () => _handleBack(context),
    );
  }
}
