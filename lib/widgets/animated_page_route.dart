import 'package:flutter/material.dart';
import '../services/animation_service.dart';

class AnimatedPageRoute<T> extends PageRouteBuilder<T> {
  AnimatedPageRoute({
    required Widget child,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final animationService = AnimationService.instance;
            
            if (!animationService.isAnimationEnabled(AnimationType.pageTransitions)) {
              // Return child directly without animation
              return child;
            }
            
            // Use default fade transition when animations are enabled
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
          transitionDuration: AnimationService.instance.getAnimationDuration(
            const Duration(milliseconds: 300),
            type: AnimationType.pageTransitions,
          ),
        );
}

// Helper function to create animated page routes
PageRoute<T> createAnimatedPageRoute<T>({
  required Widget child,
  RouteSettings? settings,
}) {
  return AnimatedPageRoute<T>(
    child: child,
    settings: settings,
  );
}
