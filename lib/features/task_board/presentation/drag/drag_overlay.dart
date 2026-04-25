import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:untitled2/features/task_board/presentation/drag/drag_controller.dart';
import 'package:untitled2/features/task_board/presentation/widgets/task_card.dart';

/// Renders the floating ghost on top of the board while a drag is active.
/// Sits inside the same Stack as the board so we don't have to manage an
/// external `OverlayEntry` lifecycle.
class DragOverlayLayer extends StatelessWidget {
  const DragOverlayLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final drag = context.watch<DragController>();
    final task = drag.task;
    if (task == null || drag.phase == DragPhase.idle) {
      return const SizedBox.shrink();
    }

    final width = drag.cardSize.width;
    final height = drag.cardSize.height;

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: drag.ghostTopLeft.dx,
            top: drag.ghostTopLeft.dy,
            width: width,
            height: height,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.95, end: 1.04),
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              builder: (context, scale, child) {
                return Transform.rotate(
                  angle: -0.025, // ~ -1.4°
                  child: Transform.scale(scale: scale, child: child),
                );
              },
              child: Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 22,
                        spreadRadius: 1,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: TaskCardVisual(task: task, ghost: true,),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
