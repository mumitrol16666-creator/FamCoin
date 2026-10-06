import 'package:flutter/material.dart';

/// Предел ширины содержимого на «широких» экранах. Некоторые телефоны с мелким
/// масштабом экрана и планшеты сообщают приложению ширину 600–900 единиц:
/// карточки растягиваются на весь экран, текст кажется мелким. В этом промежутке
/// содержимое сжимается до [maxWidth] и ставится по центру. Телефоны обычной
/// ширины и широкие экраны (от [wideFrom], там боковая панель консультанта и
/// настольная вёрстка) не затрагиваются.
class ContentWidthCap extends StatelessWidget {
  const ContentWidthCap({super.key, required this.child, this.maxWidth = 600, this.wideFrom = 900});

  final Widget child;
  final double maxWidth;
  final double wideFrom;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    if (width <= maxWidth || width >= wideFrom) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: SizedBox(
          width: maxWidth,
          // Экраны, листы и диалоги внутри узнают настоящую (суженную) ширину.
          child: MediaQuery(data: mq.copyWith(size: Size(maxWidth, mq.size.height)), child: child),
        ),
      ),
    );
  }
}
