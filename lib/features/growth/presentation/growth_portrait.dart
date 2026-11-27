import 'package:flutter/material.dart';

const avatarLabels = {'astronaut': '星际探索员', 'explorer': '自然观察员'};

/// Static, compact presentation of server-confirmed appearance slots.
class GrowthPortrait extends StatelessWidget {
  const GrowthPortrait({required this.data, this.size = 80, super.key});
  final Map<String, dynamic> data;
  final double size;
  @override
  Widget build(BuildContext context) {
    final appearance = data['appearance'] as Map;
    final assets = data['assets'] as List;
    String title(String slot) =>
        assets
            .where((a) => a['key'] == appearance[slot])
            .map((a) => a['title'] as String)
            .firstOrNull ??
        '未选择';
    final colors = Theme.of(context).colorScheme;
    final outfit = appearance['outfit'] != null;
    return Semantics(
      label:
          '我的角色：${avatarLabels[appearance['avatar']]}，装扮${title('outfit')}，徽章${title('badge')}，伙伴${title('pet')}',
      image: true,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.all(size * .1),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: outfit
                          ? colors.tertiaryContainer
                          : colors.primaryContainer,
                      border: outfit
                          ? Border.all(color: colors.tertiary, width: 3)
                          : null,
                    ),
                    child: Icon(
                      appearance['avatar'] == 'explorer'
                          ? Icons.forest
                          : Icons.rocket_launch,
                      size: size * .48,
                      color: outfit
                          ? colors.onTertiaryContainer
                          : colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              if (appearance['badge'] != null)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: Icon(
                    Icons.workspace_premium,
                    size: size * .32,
                    color: colors.primary,
                  ),
                ),
              if (appearance['pet'] != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.surface,
                    ),
                    child: Icon(
                      appearance['pet'] == 'starter_star'
                          ? Icons.star_rounded
                          : Icons.pets,
                      size: size * .34,
                      color: colors.tertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
