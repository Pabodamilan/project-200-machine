// ---------------- UI REDESIGN — PHASE A: THEME FOUNDATION ----------------
// Design tokens + shared widgets for the new "modern enterprise SaaS" look
// (light surfaces, white cards, soft grey background, electric blue
// primary, deep navy for nav areas). This file is additive only — nothing
// here replaces or removes any existing screen, widget, or the pre-existing
// `AppTheme` class in main.dart (which already owns unrelated
// primaryDark/primaryMid/accent/gradients used throughout the app; see
// main.dart's own AppTheme.light() factory, added alongside those existing
// members rather than as a competing class, to avoid a name collision).
//
// Phase A only wires this into two proof-of-concept screens (Owner
// Dashboard, Vehicle Maintenance Hub) plus the app-wide ThemeData — no
// other screen's code changes. Every other screen keeps working exactly
// as before; many will simply pick up the new default colors/radii/fonts
// passively through ThemeData, since most widgets here don't hardcode
// colors that would override that.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------- DESIGN TOKENS ----------------

class AppColors {
  AppColors._();

  static const Color navy = Color(0xFF0B1B3A);
  static const Color navySoft = Color(0xFF12254D);

  static const Color primary = Color(0xFF2563EB);
  static const Color primaryDark = Color(0xFF1D4ED8);
  static const Color primarySoft = Color(0xFFEAF1FF);

  static const Color background = Color(0xFFF4F6FA);
  static const Color card = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE5E9F2);

  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color textMuted = Color(0xFF94A3B8);

  static const Color success = Color(0xFF16A34A);
  static const Color successBg = Color(0xFFE8F7EE);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningBg = Color(0xFFFFF4DD);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerBg = Color(0xFFFDECEC);
  static const Color info = Color(0xFF0EA5E9);
}

class AppRadius {
  AppRadius._();
  static const double card = 16;
  static const double button = 12;
  static const double chip = 999;
}

class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppShadows {
  AppShadows._();

  // Very soft — blur 16, y-offset 4, 6% black, as specified.
  static List<BoxShadow> soft = [
    BoxShadow(
      color: Colors.black.withOpacity(0.06),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];
}

// ---------------- TYPOGRAPHY ----------------

// Inter has no Sinhala glyphs at all — without an explicit fallback, any
// Sinhala-script text (site/driver names, free-text notes, anything a user
// typed in Sinhala) would silently render as tofu boxes once Inter becomes
// the app's primary font. Noto Sans Sinhala covers that; it's requested via
// google_fonts (so it works identically on web, where there's no guarantee
// a Sinhala-capable system font is installed) alongside the plain family
// name (so an OS that already ships a Sinhala system font under that name
// resolves it immediately, with no network fetch at all).
List<String> get appSinhalaFontFallback => [
  GoogleFonts.notoSansSinhala().fontFamily ?? 'Noto Sans Sinhala',
  'Noto Sans Sinhala',
];

class AppText {
  AppText._();

  // GoogleFonts.inter() itself has no fontFamilyFallback parameter — the
  // fallback is applied via copyWith() on the TextStyle it returns.
  static TextStyle get title => GoogleFonts.inter(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  ).copyWith(fontFamilyFallback: appSinhalaFontFallback);

  static TextStyle get section => GoogleFonts.inter(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  ).copyWith(fontFamilyFallback: appSinhalaFontFallback);

  static TextStyle get body => GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  ).copyWith(fontFamilyFallback: appSinhalaFontFallback);

  static TextStyle get caption => GoogleFonts.inter(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  ).copyWith(fontFamilyFallback: appSinhalaFontFallback);

  static TextStyle get kpiNumber => GoogleFonts.inter(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  ).copyWith(fontFamilyFallback: appSinhalaFontFallback);
}

// ---------------- ICONS ----------------
// Only a lookup map for icons already used around the app (by concept, not
// by screen) — nothing wires these into existing screens yet; that's a
// later phase. Values are Lucide icons so a future screen-by-screen icon
// migration has a single, consistent source to pull from.
class AppIcons {
  AppIcons._();

  static const Map<String, IconData> map = {
    'dashboard': LucideIcons.layoutDashboard,
    'truck': LucideIcons.truck,
    'wrench': LucideIcons.wrench,
    'users': LucideIcons.users,
    'map-pin': LucideIcons.mapPin,
    'file-text': LucideIcons.fileText,
    'camera': LucideIcons.camera,
    'mic': LucideIcons.mic,
    'star': LucideIcons.star,
    'bell': LucideIcons.bell,
    'settings': LucideIcons.settings,
    'log-out': LucideIcons.logOut,
    'search': LucideIcons.search,
    'plus': LucideIcons.plus,
    'check': LucideIcons.check,
    'x': LucideIcons.x,
  };
}

// ---------------- MOTION ----------------

// Fade + slight slide, 200ms — used as the app-wide default Material page
// transition (see AppTheme.light()'s pageTransitionsTheme in main.dart).
// This is a NEW, separate transition from the existing FadeSlideRoute
// (350ms, used explicitly by many existing web navigation call sites) —
// that one is untouched; this only affects routes that don't specify their
// own transition (plain MaterialPageRoute pushes), which is a passive,
// app-wide visual change the task explicitly asked for.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.of(context).disableAnimations) return child;
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

// Staggered entrance for a column/grid of cards — 30-50ms delay per item,
// capped at the 8th item so a long list doesn't keep pushing visible
// entries further out. Distinct from main.dart's existing (private,
// different-file-scoped) _WebStaggeredFadeIn, which stays as-is wherever
// it's already used; this is the new foundation's equivalent for anything
// built with the new shared widgets below.
class AppStaggeredFadeIn extends StatefulWidget {
  final int index;
  final Widget child;
  final Duration perItemDelay;

  const AppStaggeredFadeIn({
    super.key,
    required this.index,
    required this.child,
    this.perItemDelay = const Duration(milliseconds: 40),
  });

  @override
  State<AppStaggeredFadeIn> createState() => _AppStaggeredFadeInState();
}

class _AppStaggeredFadeInState extends State<AppStaggeredFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    _controller = AnimationController(
      vsync: this,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 260),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(_fade);
    final cappedIndex = widget.index.clamp(0, 7);
    final delay = reduceMotion
        ? Duration.zero
        : widget.perItemDelay * cappedIndex;
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ---------------- SHARED WIDGETS ----------------

// White card, radius 16, soft border + shadow, optional tap with ripple and
// a subtle press-down scale (0.97).
class AppCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.onTap,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  double _scale = 1.0;

  void _setPressed(bool pressed) {
    if (widget.onTap == null) return;
    if (MediaQuery.of(context).disableAnimations) return;
    setState(() => _scale = pressed ? 0.97 : 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final card = AnimatedScale(
      scale: _scale,
      duration: const Duration(milliseconds: 100),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.soft,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: (_) => _setPressed(true),
              onTapUp: (_) => _setPressed(false),
              onTapCancel: () => _setPressed(false),
              child: Padding(padding: widget.padding, child: widget.child),
            ),
          ),
        ),
      ),
    );
    return card;
  }
}

// Icon + label + big animated number, optional delta line (e.g. "+12%" in
// success/danger color depending on sign).
class KpiCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final num value;
  final String? valuePrefix;
  final String? valueSuffix;
  final double? delta;
  final String? deltaLabel;
  // Optional per-instance accent, for a row of KPIs where the icon color
  // itself is useful at-a-glance information (e.g. distinguishing several
  // "Total X" counts) — defaults to the uniform primary/primarySoft pair
  // used everywhere else in the new design system when omitted.
  final Color? iconColor;
  final Color? iconBackground;

  const KpiCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.valuePrefix,
    this.valueSuffix,
    this.delta,
    this.deltaLabel,
    this.iconColor,
    this.iconBackground,
  });

  @override
  State<KpiCard> createState() => _KpiCardState();
}

class _KpiCardState extends State<KpiCard> {
  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final delta = widget.delta;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.iconBackground ??
                      (widget.iconColor?.withOpacity(0.12) ??
                          AppColors.primarySoft),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  widget.icon,
                  color: widget.iconColor ?? AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  widget.label,
                  style: AppText.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: 0,
              end: widget.value.toDouble(),
            ),
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) {
              final isWhole = widget.value == widget.value.roundToDouble();
              final display = isWhole
                  ? animatedValue.round().toString()
                  : animatedValue.toStringAsFixed(1);
              return Text(
                '${widget.valuePrefix ?? ''}$display${widget.valueSuffix ?? ''}',
                style: AppText.kpiNumber,
              );
            },
          ),
          if (delta != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  delta >= 0 ? LucideIcons.trendingUp : LucideIcons.trendingDown,
                  size: 14,
                  color: delta >= 0 ? AppColors.success : AppColors.danger,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.deltaLabel ??
                      '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%',
                  style: AppText.caption.copyWith(
                    color: delta >= 0 ? AppColors.success : AppColors.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// Status -> color chip. Looks up the status text (case-insensitive) against
// a small set of known buckets; anything unrecognized falls back to a
// neutral grey rather than guessing.
class StatusChip extends StatelessWidget {
  final String status;

  const StatusChip({super.key, required this.status});

  static const Set<String> _success = {
    'good',
    'suitable',
    'completed',
    'active',
    'approved',
    'verified',
    'closed',
    'diagnosed',
    'safe to run',
    'repair created',
    'paid',
    'pass',
  };
  static const Set<String> _danger = {
    'bad',
    'not suitable',
    'not_suitable',
    'rejected',
    'failed',
    'critical',
    'high',
    'do not run',
    'fail',
  };
  static const Set<String> _warning = {
    'replace',
    'pending',
    'needs attention',
    'medium',
    'restricted',
    'under review',
    'partial',
    'returned',
    'not billed',
  };
  static const Set<String> _info = {
    'in progress',
    'running',
    'low',
    'open',
    'in repair',
    'final inspection',
    'pending approval',
    'quoting',
  };

  (Color, Color) _colorsFor(String normalized) {
    if (_success.contains(normalized)) return (AppColors.success, AppColors.successBg);
    if (_danger.contains(normalized)) return (AppColors.danger, AppColors.dangerBg);
    if (_warning.contains(normalized)) return (AppColors.warning, AppColors.warningBg);
    if (_info.contains(normalized)) return (AppColors.info, AppColors.primarySoft);
    return (AppColors.textSecondary, AppColors.background);
  }

  @override
  Widget build(BuildContext context) {
    final normalized = status.trim().toLowerCase().replaceAll('_', ' ');
    final (fg, bg) = _colorsFor(normalized);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 200),
        style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w600),
        child: Text(status.toUpperCase()),
      ),
    );
  }
}

// Title + optional trailing action — used above a card grid/list/section.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppText.section)),
        if (actionLabel != null && onAction != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: AppText.section, textAlign: TextAlign.center),
            if (hint != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                hint!,
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  final String? message;
  const LoadingState({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 2.5,
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(message!, style: AppText.caption),
          ],
        ],
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorState({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.alertCircle, size: 36, color: AppColors.danger),
            const SizedBox(height: AppSpacing.md),
            Text(message, style: AppText.body, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: const Text('RETRY'),
            ),
          ],
        ),
      ),
    );
  }
}

// Shared confirm dialog in the new look — returns true only if the user
// tapped the confirm action.
Future<bool> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(title, style: AppText.section),
      content: Text(message, style: AppText.body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        destructive
            ? ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                child: Text(confirmLabel),
              )
            : ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
      ],
    ),
  );
  return result ?? false;
}

// Standard page shell: soft-grey background, centred max-width-1200 content
// on web (so a wide desktop browser doesn't stretch content edge-to-edge),
// standard padding. Purely a layout/background convenience — still just a
// Scaffold underneath, so it doesn't change navigation/AppBar behavior.
class AppPageScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;

  const AppPageScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: kIsWeb ? 1200 : double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: body,
          ),
        ),
      ),
    );
  }
}
