// Interactive "Truck Parts Map" for the Vehicle Maintenance dashboard.
//
// A real photo of the company's own tipper truck (assets/images/
// tipper_truck_side.jpg — used as-is, never redrawn/traced/edited) with
// an invisible hotspot overlay. Hovering (web) or tapping (mobile) a part
// highlights it and shows a detail card with the repair codes logged
// against it, read-only service-due status, and a link into the existing
// repair history. Reachable from VehicleMaintenanceHubScreen's new
// "Vehicle Health" tile and from TruckProfileScreen (which passes its own
// vehicleNumber in) — both gated to admin/owner/management, see
// VehicleHealthScreen's role check.
//
// Kept in its own file on purpose (vs. growing main.dart further) — it
// only needs main.dart's PUBLIC members (RepairItemStatus,
// ServiceRecordStatus/ServiceItemDueStatus, fetchVehicleServiceOverview,
// timeoutFirstEventOnly, RepairHistoryScreen, pushWebAware) and the
// design-system tokens from app_theme.dart. main.dart importing this file
// back is an ordinary two-way Dart import, not a problem for the
// compiler.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../main.dart';

// ---------------------------------------------------------------------------
// Part catalog + repair-category mapping
// ---------------------------------------------------------------------------

/// Draw order (bottom to top) — also the order checked in reverse for hit
/// testing, so a later (visually topmost) part wins where paths overlap.
/// Matches the photo's own layering: frame first, then the body panels
/// that sit on it, wheels last since they're the most forward element.
const List<String> kTruckPartIds = [
  'chassis',
  'tipperBody',
  'cab',
  'hydraulic',
  'engine',
  'cooling',
  'fuelTank',
  'electrical',
  'exhaust',
  'frontAxle',
  'rearAxle',
];

const Map<String, String> kTruckPartLabels = {
  'cab': 'Cab',
  'engine': 'Engine',
  'cooling': 'Cooling System',
  'tipperBody': 'Tipper Body',
  'hydraulic': 'Hydraulic Ram',
  'fuelTank': 'Fuel Tank',
  'frontAxle': 'Front Axle & Brakes',
  'rearAxle': 'Rear Axle & Brakes',
  'chassis': 'Chassis & Suspension',
  'electrical': 'Battery & Electrical',
  'exhaust': 'Exhaust',
  'tyres': 'Tyres (all wheels)',
};

/// partId -> repair_categories codes (from kDefaultRepairCategories in
/// main.dart). A best-effort mapping — several of the 14 seeded categories
/// don't have one unambiguous visual home on a side-view photo (no
/// dedicated "brakes-only" or "drivetrain" shape), so the choices below are
/// judgment calls called out in this feature's report for correction:
///   - BRK (Brakes) -> both frontAxle and rearAxle, since a repair record
///     doesn't say which end.
///   - STR (Steering) -> frontAxle only (steering acts on the front wheels).
///   - SUS (Suspension) -> chassis, matching this part's own "frame +
///     suspension" description.
///   - BDY (Chassis and body) -> tipperBody (the dump bed is the visible
///     "body"); chassis already owns the frame/suspension story above, so
///     BDY isn't duplicated there too.
///   - GBX (Gearbox/transmission) and CLT (Clutch) have no clean part on a
///     side-view silhouette (they're hidden components, not a distinct
///     visible shape) — left unmapped, so they surface in the "Other /
///     General" row instead of being forced onto a part they don't
///     visually represent.
///   - cab and exhaust have no seeded category of their own — left
///     unmapped (empty list) rather than guessing; their detail card just
///     shows no codes.
///   - tyres (TYR) is drawn as a separate chip, not a spatial part on the
///     truck (see VehicleHealthScreen) — overlapping thin tyre rings on
///     top of the axle circles would be a fragile, error-prone hit target,
///     so "all wheels" stays a distinct, reliably-tappable chip instead.
const Map<String, List<String>> partToCategoryCodes = {
  'cab': [],
  'engine': ['ENG'],
  'cooling': ['COL'],
  'tipperBody': ['BDY'],
  'hydraulic': ['HYD'],
  'fuelTank': ['FUE'],
  'frontAxle': ['BRK', 'STR'],
  'rearAxle': ['BRK'],
  'chassis': ['SUS'],
  'electrical': ['ELE', 'LGT'],
  'exhaust': [],
};

/// TYR is handled as its own chip (see partToCategoryCodes' doc comment),
/// not folded into the spatial map above.
const String kTyresCategoryCode = 'TYR';

/// Every mapped code, flattened — anything NOT in here (OTH, GBX, CLT, plus
/// TYR since it's handled separately above, plus any future category) goes
/// to the "Other / General" chip row.
Set<String> get kMappedCategoryCodes =>
    partToCategoryCodes.values.expand((c) => c).toSet();

/// Best-effort keyword match from a service_items schedule's free-text
/// `name` to a part — service_items has no fixed code/id scheme like
/// repair_categories does, so this is intentionally fuzzy, read-only, and
/// never invents a km value (see ServiceItemDue, already computed by
/// fetchVehicleServiceOverview).
const Map<String, List<String>> _partServiceKeywords = {
  'engine': ['engine', 'oil'],
  'cooling': ['coolant', 'radiator', 'cooling'],
  'hydraulic': ['hydraulic', 'ram', 'tipper'],
  'fuelTank': ['fuel'],
  'frontAxle': ['brake'],
  'rearAxle': ['brake'],
  'chassis': ['suspension', 'chassis'],
  'electrical': ['battery', 'electrical'],
  'tipperBody': ['body'],
  'exhaust': ['exhaust'],
  'cab': ['cab'],
};

String? servicePartKeywordMatch(String scheduleName) {
  final lower = scheduleName.toLowerCase();
  for (final entry in _partServiceKeywords.entries) {
    if (entry.value.any(lower.contains)) return entry.key;
  }
  return null;
}

// Small local mirror of main.dart's private _serviceDueStatusColor (not
// reachable from here — Dart privacy is per-file) — used only for the
// vehicle selector's instant status dot.
Color _fleetDotColor(String status) {
  switch (status) {
    case ServiceItemDueStatus.missed:
    case ServiceItemDueStatus.overdue:
      return AppColors.danger;
    case ServiceItemDueStatus.dueSoon:
    case ServiceItemDueStatus.kmUnknown:
      return AppColors.warning;
    case ServiceItemDueStatus.neverServiced:
      return AppColors.textMuted;
    default:
      return AppColors.success;
  }
}

// ---------------------------------------------------------------------------
// Photo asset + hotspot geometry
// ---------------------------------------------------------------------------

/// The real photo, used as-is — never redrawn, traced or pixel-edited.
const String kTruckImageAsset = 'assets/images/tipper_truck_side.jpg';

/// The pixel dimensions the hotspot polygons below were measured against.
/// The real decoded asset is read at runtime (see
/// _TruckPartsMapState._resolveImageSize) and used instead whenever it's
/// available — this is only the fallback for the first frame/a failed
/// resolve, and it's what "normalize to 0..1" below divides by.
const Size kReferenceImageSize = Size(724, 500);

/// Hotspot polygons in REFERENCE PIXEL space (724x500) — exactly the
/// calibration coordinates measured against the photo. If they drift out
/// of alignment after a different crop/export of the same photo, open
/// this screen in a debug build and tap "Show hotspots" (top-right of the
/// card) to see them drawn translucently over the real image and adjust
/// the numbers here.
const Map<String, List<Offset>> _kReferencePolygons = {
  'tipperBody': [
    Offset(62, 152),
    Offset(420, 158),
    Offset(466, 110),
    Offset(541, 104),
    Offset(512, 126),
    Offset(448, 248),
    Offset(405, 282),
    Offset(265, 292),
    Offset(70, 290),
  ],
  'cab': [
    Offset(505, 162),
    Offset(530, 135),
    Offset(626, 134),
    Offset(648, 170),
    Offset(656, 238),
    Offset(661, 312),
    Offset(560, 314),
    Offset(520, 300),
    Offset(505, 262),
  ],
  'hydraulic': [
    Offset(438, 150),
    Offset(478, 148),
    Offset(496, 268),
    Offset(446, 282),
  ],
  'engine': [
    Offset(480, 268),
    Offset(560, 262),
    Offset(606, 276),
    Offset(612, 318),
    Offset(560, 332),
    Offset(484, 336),
  ],
  'cooling': [
    Offset(628, 262),
    Offset(660, 258),
    Offset(664, 332),
    Offset(630, 336),
  ],
  'exhaust': [
    Offset(494, 128),
    Offset(540, 128),
    Offset(540, 152),
    Offset(494, 152),
  ],
  'fuelTank': [
    Offset(316, 298),
    Offset(402, 298),
    Offset(402, 350),
    Offset(316, 350),
  ],
  'electrical': [
    Offset(290, 322),
    Offset(318, 322),
    Offset(318, 352),
    Offset(290, 352),
  ],
  'chassis': [
    Offset(92, 292),
    Offset(480, 292),
    Offset(480, 326),
    Offset(92, 326),
  ],
};

// Wheels are circles, not polygons.
const Offset _kFrontAxleCenter = Offset(545, 360);
const double _kFrontAxleRadius = 55;
const List<Offset> _kRearAxleCenters = [Offset(203, 364), Offset(252, 360)];
const List<double> _kRearAxleRadii = [52, 46];

class TruckPartGeometry {
  final String id;
  // Normalized to 0..1 against kReferenceImageSize — scale by the actual
  // contain-rect's width/height at paint/hit-test time.
  final Path normalizedPath;
  final Offset normalizedCentroid;
  final Rect normalizedBounds;
  const TruckPartGeometry({
    required this.id,
    required this.normalizedPath,
    required this.normalizedCentroid,
    required this.normalizedBounds,
  });
}

Path _referencePathFor(String id) {
  if (id == 'frontAxle') {
    return Path()
      ..addOval(Rect.fromCircle(center: _kFrontAxleCenter, radius: _kFrontAxleRadius));
  }
  if (id == 'rearAxle') {
    final path = Path();
    for (var i = 0; i < _kRearAxleCenters.length; i++) {
      path.addOval(Rect.fromCircle(center: _kRearAxleCenters[i], radius: _kRearAxleRadii[i]));
    }
    return path;
  }
  final points = _kReferencePolygons[id]!;
  return Path()..addPolygon(points, true);
}

/// Area-weighted polygon centroid (not a plain vertex average) — falls
/// back to the vertex average only for a degenerate (zero-area) polygon.
Offset _polygonCentroid(List<Offset> pts) {
  var area = 0.0;
  var cx = 0.0;
  var cy = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p0 = pts[i];
    final p1 = pts[(i + 1) % pts.length];
    final cross = p0.dx * p1.dy - p1.dx * p0.dy;
    area += cross;
    cx += (p0.dx + p1.dx) * cross;
    cy += (p0.dy + p1.dy) * cross;
  }
  area *= 0.5;
  if (area == 0) {
    final avgX = pts.map((p) => p.dx).reduce((a, b) => a + b) / pts.length;
    final avgY = pts.map((p) => p.dy).reduce((a, b) => a + b) / pts.length;
    return Offset(avgX, avgY);
  }
  return Offset(cx / (6 * area), cy / (6 * area));
}

Offset _referenceCentroidFor(String id) {
  if (id == 'frontAxle') return _kFrontAxleCenter;
  if (id == 'rearAxle') {
    // Weighted by area (radius^2) — the two rear wheels have different
    // radii in the reference coordinates.
    var sumX = 0.0, sumY = 0.0, sumW = 0.0;
    for (var i = 0; i < _kRearAxleCenters.length; i++) {
      final w = _kRearAxleRadii[i] * _kRearAxleRadii[i];
      sumX += _kRearAxleCenters[i].dx * w;
      sumY += _kRearAxleCenters[i].dy * w;
      sumW += w;
    }
    return Offset(sumX / sumW, sumY / sumW);
  }
  return _polygonCentroid(_kReferencePolygons[id]!);
}

Path _normalize(Path referencePath) {
  final matrix = Matrix4.identity()
    ..scale(1 / kReferenceImageSize.width, 1 / kReferenceImageSize.height, 1.0);
  return referencePath.transform(matrix.storage);
}

Offset _normalizeOffset(Offset reference) => Offset(
      reference.dx / kReferenceImageSize.width,
      reference.dy / kReferenceImageSize.height,
    );

List<TruckPartGeometry>? _cachedGeometry;

/// Built once (not recreated in build) — pure function of the constants
/// above, so a module-level cache is safe and avoids re-normalizing every
/// Path on every frame.
List<TruckPartGeometry> buildTruckPartGeometry() {
  final cached = _cachedGeometry;
  if (cached != null) return cached;
  final result = <TruckPartGeometry>[];
  for (final id in kTruckPartIds) {
    final referencePath = _referencePathFor(id);
    final normalizedPath = _normalize(referencePath);
    result.add(TruckPartGeometry(
      id: id,
      normalizedPath: normalizedPath,
      normalizedCentroid: _normalizeOffset(_referenceCentroidFor(id)),
      normalizedBounds: normalizedPath.getBounds(),
    ));
  }
  _cachedGeometry = result;
  return result;
}

/// Where BoxFit.contain actually places the image within `container` —
/// the SAME rect Image.asset(fit: BoxFit.contain) renders into, so the
/// hotspot overlay lines up with the real picture exactly, letterboxing
/// included.
Rect computeContainRect(Size container, Size imageSize) {
  final fitted = applyBoxFit(BoxFit.contain, imageSize, container);
  final destination = fitted.destination;
  final left = (container.width - destination.width) / 2;
  final top = (container.height - destination.height) / 2;
  return Rect.fromLTWH(left, top, destination.width, destination.height);
}

Path _mapToRect(Path normalizedPath, Rect rect) {
  final matrix = Matrix4.identity()
    ..translate(rect.left, rect.top)
    ..scale(rect.width, rect.height, 1.0);
  return normalizedPath.transform(matrix.storage);
}

Offset _mapOffsetToRect(Offset normalized, Rect rect) =>
    rect.topLeft + Offset(normalized.dx * rect.width, normalized.dy * rect.height);

// ---------------------------------------------------------------------------
// Overlay painter — scrim-with-cutout + highlight + status dots +
// calibration. The photo itself is a separate Image.asset layer (see
// TruckPartsMap), cached behind its own RepaintBoundary so it's never
// re-rasterized just because this overlay is animating.
// ---------------------------------------------------------------------------

class _TruckOverlayPainter extends CustomPainter {
  final List<TruckPartGeometry> parts;
  final Rect containRect;
  final String? highlightedPartId;
  final Set<String> redPartIds;
  final Set<String> amberPartIds;
  final Set<String> activePartIds;
  final double entrance; // 0..1
  final double highlightT; // 0..1, hover/select transition
  final double pulse; // 0..1, red-dot pulse phase
  final bool showCalibration;

  _TruckOverlayPainter({
    required this.parts,
    required this.containRect,
    required this.highlightedPartId,
    required this.redPartIds,
    required this.amberPartIds,
    required this.activePartIds,
    required this.entrance,
    required this.highlightT,
    required this.pulse,
    required this.showCalibration,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (containRect.width <= 0 || containRect.height <= 0) return;

    canvas.saveLayer(null, Paint()..color = Colors.white.withOpacity(entrance));

    final highlighted = highlightedPartId == null
        ? null
        : parts.where((p) => p.id == highlightedPartId).firstOrNull;

    if (highlighted != null && highlightT > 0) {
      final screenPath = _mapToRect(highlighted.normalizedPath, containRect);
      final fullRect = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
      final scrimPath = Path.combine(PathOperation.difference, fullRect, screenPath);
      canvas.drawPath(
        scrimPath,
        Paint()..color = Colors.black.withOpacity(0.45 * highlightT),
      );

      canvas.drawPath(
        screenPath,
        Paint()..color = AppColors.primary.withOpacity(0.25 * highlightT),
      );
      canvas.drawPath(
        screenPath,
        Paint()
          ..color = AppColors.primary.withOpacity(0.8 * highlightT)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    for (final part in parts) {
      final screenCentroid = _mapOffsetToRect(part.normalizedCentroid, containRect);
      Color dotColor;
      if (redPartIds.contains(part.id)) {
        dotColor = AppColors.danger;
      } else if (amberPartIds.contains(part.id)) {
        dotColor = AppColors.warning;
      } else if (activePartIds.contains(part.id)) {
        dotColor = AppColors.success;
      } else {
        continue;
      }
      if (redPartIds.contains(part.id)) {
        canvas.drawCircle(
          screenCentroid,
          7 + 6 * pulse,
          Paint()..color = dotColor.withOpacity(0.35 * (1 - pulse)),
        );
      }
      canvas.drawCircle(screenCentroid, 7, Paint()..color = dotColor);
      canvas.drawCircle(
        screenCentroid,
        7,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    if (showCalibration) {
      for (final part in parts) {
        final screenPath = _mapToRect(part.normalizedPath, containRect);
        canvas.drawPath(
          screenPath,
          Paint()
            ..color = Colors.cyanAccent.withOpacity(0.35)
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          screenPath,
          Paint()
            ..color = Colors.blueAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        final labelCentroid = _mapOffsetToRect(part.normalizedCentroid, containRect);
        final painter = TextPainter(
          text: TextSpan(
            text: kTruckPartLabels[part.id] ?? part.id,
            style: const TextStyle(
              color: Colors.black,
              backgroundColor: Colors.white,
              fontSize: 10,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(canvas, labelCentroid - Offset(painter.width / 2, painter.height / 2));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TruckOverlayPainter oldDelegate) {
    return oldDelegate.containRect != containRect ||
        oldDelegate.highlightedPartId != highlightedPartId ||
        oldDelegate.redPartIds != redPartIds ||
        oldDelegate.amberPartIds != amberPartIds ||
        oldDelegate.activePartIds != activePartIds ||
        oldDelegate.entrance != entrance ||
        oldDelegate.highlightT != highlightT ||
        oldDelegate.pulse != pulse ||
        oldDelegate.showCalibration != showCalibration;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

// ---------------------------------------------------------------------------
// Interactive widget
// ---------------------------------------------------------------------------

class TruckPartsMap extends StatefulWidget {
  final String? highlightedPartId;
  final Set<String> redPartIds;
  final Set<String> amberPartIds;
  final Set<String> activePartIds;
  final ValueChanged<String?> onHover;
  final ValueChanged<String?> onTap;

  const TruckPartsMap({
    super.key,
    required this.highlightedPartId,
    required this.redPartIds,
    required this.amberPartIds,
    required this.activePartIds,
    required this.onHover,
    required this.onTap,
  });

  @override
  State<TruckPartsMap> createState() => _TruckPartsMapState();
}

class _TruckPartsMapState extends State<TruckPartsMap> with TickerProviderStateMixin {
  late final List<TruckPartGeometry> _parts = buildTruckPartGeometry();
  late final AnimationController _entranceController;
  late final AnimationController _highlightController;
  late final AnimationController _pulseController;
  Size _imageSize = kReferenceImageSize;
  bool _showCalibration = false;
  ImageStream? _imageStream;
  late final ImageStreamListener _imageStreamListener;

  @override
  void initState() {
    super.initState();
    final reduceMotion =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _highlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    if (reduceMotion) {
      _entranceController.value = 1.0;
    } else {
      _entranceController.forward();
    }
    _imageStreamListener = ImageStreamListener(_onImageResolved, onError: _onImageResolveError);
    _resolveImageSize();
  }

  @override
  void didUpdateWidget(TruckPartsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.highlightedPartId != widget.highlightedPartId) {
      if (widget.highlightedPartId != null) {
        _highlightController.animateTo(1.0, curve: Curves.easeOutCubic);
      } else {
        _highlightController.animateBack(0.0, curve: Curves.easeOutCubic);
      }
    }
  }

  void _resolveImageSize() {
    final stream = const AssetImage(kTruckImageAsset).resolve(ImageConfiguration.empty);
    _imageStream = stream;
    stream.addListener(_imageStreamListener);
  }

  void _onImageResolved(ImageInfo info, bool synchronousCall) {
    final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
    if (mounted && size != _imageSize) {
      setState(() => _imageSize = size);
    }
  }

  void _onImageResolveError(Object exception, StackTrace? stackTrace) {
    // Keeps the reference 724x500 aspect ratio for hotspot alignment;
    // Image.asset's own errorBuilder (below) handles the visible message.
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageStreamListener);
    _entranceController.dispose();
    _highlightController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String? _hitTest(Offset localPosition, Rect containRect) {
    if (!containRect.contains(localPosition)) return null;
    final normalized = Offset(
      (localPosition.dx - containRect.left) / containRect.width,
      (localPosition.dy - containRect.top) / containRect.height,
    );
    for (final part in _parts.reversed) {
      if (part.normalizedPath.contains(normalized)) return part.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = width * (kReferenceImageSize.height / kReferenceImageSize.width);
        final renderSize = Size(width, height);
        final containRect = computeContainRect(renderSize, _imageSize);
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              // Static photo layer — RepaintBoundary so hover/highlight
              // animation repaints never re-rasterize the image.
              Positioned.fill(
                child: RepaintBoundary(
                  child: Container(
                    color: Colors.white,
                    child: Image.asset(
                      kTruckImageAsset,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Center(
                        child: Text(
                          'Truck image missing',
                          style: AppText.caption.copyWith(color: AppColors.textMuted),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.basic,
                onHover: (event) {
                  final hit = _hitTest(event.localPosition, containRect);
                  widget.onHover(hit);
                },
                onExit: (_) => widget.onHover(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    final hit = _hitTest(details.localPosition, containRect);
                    widget.onTap(hit);
                  },
                  child: AnimatedBuilder(
                    animation: Listenable.merge(
                      [_entranceController, _highlightController, _pulseController],
                    ),
                    builder: (context, _) {
                      return CustomPaint(
                        size: renderSize,
                        painter: _TruckOverlayPainter(
                          parts: _parts,
                          containRect: containRect,
                          highlightedPartId: widget.highlightedPartId,
                          redPartIds: widget.redPartIds,
                          amberPartIds: widget.amberPartIds,
                          activePartIds: widget.activePartIds,
                          entrance: _entranceController.value,
                          highlightT: _highlightController.value,
                          pulse: _pulseController.value,
                          showCalibration: _showCalibration,
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Accessible, guaranteed->=44px touch-target equivalent of
              // the precise Path.contains hit testing above — a screen
              // reader (or a finger on a small part) uses these instead
              // of needing pixel-perfect pointer placement.
              for (final part in _parts)
                _touchTarget(part, containRect),
              if (kDebugMode)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Semantics(
                    button: true,
                    label: 'Show hotspots (debug only)',
                    child: Material(
                      color: AppColors.card.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        onTap: () => setState(() => _showCalibration = !_showCalibration),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Text(
                            _showCalibration ? 'Hide hotspots' : 'Show hotspots',
                            style: AppText.caption,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _touchTarget(TruckPartGeometry part, Rect containRect) {
    final bounds = Rect.fromLTWH(
      containRect.left + part.normalizedBounds.left * containRect.width,
      containRect.top + part.normalizedBounds.top * containRect.height,
      part.normalizedBounds.width * containRect.width,
      part.normalizedBounds.height * containRect.height,
    );
    const minSize = 44.0;
    final padX = bounds.width >= minSize ? 0.0 : (minSize - bounds.width) / 2;
    final padY = bounds.height >= minSize ? 0.0 : (minSize - bounds.height) / 2;
    return Positioned(
      left: bounds.left - padX,
      top: bounds.top - padY,
      width: bounds.width + 2 * padX,
      height: bounds.height + 2 * padY,
      child: Semantics(
        button: true,
        label: '${kTruckPartLabels[part.id] ?? part.id}'
            '${widget.redPartIds.contains(part.id) ? ', has open repairs' : ''}'
            '${widget.amberPartIds.contains(part.id) ? ', pending approval' : ''}',
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => widget.onTap(part.id),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data model for the detail card
// ---------------------------------------------------------------------------

class PartRepairSummary {
  final int openCount;
  final int pendingApprovalCount;
  final int completedCount;
  final List<Map<String, dynamic>> latestCodes; // up to 8, newest first
  const PartRepairSummary({
    required this.openCount,
    required this.pendingApprovalCount,
    required this.completedCount,
    required this.latestCodes,
  });

  bool get isEmpty =>
      openCount == 0 && pendingApprovalCount == 0 && completedCount == 0;

  static const empty = PartRepairSummary(
    openCount: 0,
    pendingApprovalCount: 0,
    completedCount: 0,
    latestCodes: [],
  );
}

const List<String> _kOpenStatuses = [
  RepairItemStatus.reported,
  RepairItemStatus.listed,
  RepairItemStatus.inProgress,
];

/// Pure — groups repair docs by categoryCode, then rolls each part's
/// summary up from every category code mapped to it. `otherCodes` is
/// whatever's left over (see kMappedCategoryCodes), surfaced by the
/// caller as the "Other / General" row.
Map<String, PartRepairSummary> summarizeRepairsByPart(
  List<Map<String, dynamic>> repairs,
) {
  final byCategory = <String, List<Map<String, dynamic>>>{};
  for (final r in repairs) {
    final code = (r['categoryCode'] ?? '').toString();
    byCategory.putIfAbsent(code, () => []).add(r);
  }

  PartRepairSummary summaryFor(List<String> codes) {
    final docs = codes
        .expand((c) => byCategory[c] ?? const <Map<String, dynamic>>[])
        .toList()
      ..sort((a, b) {
        final at = a['reportedAt'];
        final bt = b['reportedAt'];
        if (at is Timestamp && bt is Timestamp) return bt.compareTo(at);
        return 0;
      });
    final open = docs.where((r) => _kOpenStatuses.contains(r['status'])).length;
    final pending =
        docs.where((r) => r['status'] == RepairItemStatus.donePendingApproval).length;
    final completed = docs.where((r) => r['status'] == RepairItemStatus.completed).length;
    return PartRepairSummary(
      openCount: open,
      pendingApprovalCount: pending,
      completedCount: completed,
      latestCodes: docs.take(8).toList(),
    );
  }

  final result = <String, PartRepairSummary>{};
  for (final entry in partToCategoryCodes.entries) {
    if (entry.value.isEmpty) {
      result[entry.key] = PartRepairSummary.empty;
    } else {
      result[entry.key] = summaryFor(entry.value);
    }
  }
  result['tyres'] = summaryFor([kTyresCategoryCode]);

  final mapped = kMappedCategoryCodes..add(kTyresCategoryCode);
  final otherCodes = byCategory.keys.where((c) => !mapped.contains(c)).toList();
  result['__other__'] = summaryFor(otherCodes);
  return result;
}

// ---------------------------------------------------------------------------
// VEHICLE HEALTH screen
// ---------------------------------------------------------------------------

// Instant, Traccar-free km placeholder (peekLastKnownKm, one
// vehicle_km_cache doc read) followed by the real Traccar-first fetch
// (fetchBestKnownKm) — same two-phase pattern as main.dart's
// _TruckServiceStatusBanner, factored out here since VehicleHealthScreen
// shows a plain km line (not a due-items card). Keyed by vehicleNumber at
// its call site in _buildBody, so switching vehicles remounts this fresh
// rather than needing its own didUpdateWidget handling.
class _VehicleKmLine extends StatefulWidget {
  final String vehicleNumber;
  final FirebaseFirestore? db;
  const _VehicleKmLine({super.key, required this.vehicleNumber, this.db});

  @override
  State<_VehicleKmLine> createState() => _VehicleKmLineState();
}

class _VehicleKmLineState extends State<_VehicleKmLine> {
  late Future<({double? km, String source})> _future;
  ({double km, String source})? _peek;

  @override
  void initState() {
    super.initState();
    _future = fetchBestKnownKm(widget.vehicleNumber, db: widget.db);
    peekLastKnownKm(widget.vehicleNumber, db: widget.db).then((p) {
      if (p != null && mounted) setState(() => _peek = p);
    });
  }

  void _retry() {
    setState(() {
      _future = fetchBestKnownKm(widget.vehicleNumber, db: widget.db, forceRefresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({double? km, String source})>(
      future: _future,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        String kmText;
        String sourceText;
        if (loading && _peek != null) {
          kmText = _peek!.km.toStringAsFixed(0);
          sourceText = _peek!.source;
        } else if (loading) {
          return const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox(
              height: 12,
              width: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        } else if (snap.hasError) {
          kmText = '—';
          sourceText = 'unavailable';
        } else {
          final r = snap.data!;
          kmText = r.km?.toStringAsFixed(0) ?? '—';
          sourceText = r.source;
        }
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Expanded(
                child: Text('Current km: $kmText ($sourceText)', style: AppText.caption),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: SizedBox(
                    height: 10,
                    width: 10,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              InkWell(
                onTap: _retry,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.refresh, size: 14),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// admin / owner / management only — attached from
/// VehicleMaintenanceHubScreen's "Vehicle Health" tile (no vehicle
/// preselected) and from TruckProfileScreen (passes its own
/// vehicleNumber in as `initialVehicleNumber`).
class VehicleHealthScreen extends StatefulWidget {
  final String? initialVehicleNumber;
  final FirebaseFirestore? firestoreOverride;
  final String? currentUidOverride;
  const VehicleHealthScreen({
    super.key,
    this.initialVehicleNumber,
    this.firestoreOverride,
    this.currentUidOverride,
  });

  @override
  State<VehicleHealthScreen> createState() => _VehicleHealthScreenState();
}

class _VehicleHealthScreenState extends State<VehicleHealthScreen> {
  FirebaseFirestore get _db => widget.firestoreOverride ?? FirebaseFirestore.instance;
  String? get _uid => widget.currentUidOverride ?? FirebaseAuth.instance.currentUser?.uid;

  bool _busy = false;
  late final Future<bool> _accessFuture = _checkAccess();
  late final Future<List<String>> _vehiclesFuture = _loadVehicleNumbers();
  // Instant, Traccar-free due status per vehicle (vehicle_km_cache's one
  // bulk read) — just enough to color a small dot per vehicle in the
  // selector below; a vehicle missing from this map simply gets no dot.
  late final Future<Map<String, String>> _fleetStatusFuture = _loadFleetStatus();

  String? _vehicleNumber;
  String? _hoveredPartId;
  String? _pinnedPartId;

  Stream<QuerySnapshot>? _repairsStream;
  String? _repairsStreamVehicle;

  Future<({double? currentKm, String kmSource, List<ServiceItemDue> due})>? _serviceFuture;
  String? _serviceFutureVehicle;

  @override
  void initState() {
    super.initState();
    _vehicleNumber = widget.initialVehicleNumber;
  }

  Future<bool> _checkAccess() async {
    final uid = _uid;
    if (uid == null) return false;
    final doc = await _db.collection('users').doc(uid).get();
    final role = doc.data()?['role'] as String?;
    return role == 'admin' || role == 'owner' || role == 'management';
  }

  Future<List<String>> _loadVehicleNumbers() async {
    final snap = await _db.collection('trucks').get();
    final numbers = snap.docs
        .map((d) => d.data())
        .where((d) => d['isCompanyTruck'] == true)
        .map((d) => (d['truckNumber'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return numbers;
  }

  Future<Map<String, String>> _loadFleetStatus() async {
    try {
      final overview = await fetchFleetServiceOverviewFromCache(db: _db);
      return {for (final o in overview) o.vehicleNumber: o.worstStatus};
    } catch (e) {
      debugPrint('VehicleHealthScreen: fleet status load error: $e');
      return const {};
    }
  }

  // Cached in State, not recreated in build — same convention as every
  // other repair-v2 screen's _stream field.
  Stream<QuerySnapshot> _streamFor(String vehicleNumber) {
    if (_repairsStream == null || _repairsStreamVehicle != vehicleNumber) {
      _repairsStreamVehicle = vehicleNumber;
      _repairsStream = timeoutFirstEventOnly(
        _db
            .collection('repairs')
            .where('vehicleNumber', isEqualTo: vehicleNumber)
            .orderBy('reportedAt', descending: true)
            .snapshots(),
        const Duration(seconds: 15),
        onTimeout: () => TimeoutException('Taking too long to load repairs.'),
      );
    }
    return _repairsStream!;
  }

  Future<({double? currentKm, String kmSource, List<ServiceItemDue> due})> _serviceOverviewFor(
    String vehicleNumber,
  ) {
    if (_serviceFuture == null || _serviceFutureVehicle != vehicleNumber) {
      _serviceFutureVehicle = vehicleNumber;
      _serviceFuture = fetchVehicleServiceOverview(vehicleNumber, db: _db)
          .then((r) => (currentKm: r.currentKm, kmSource: r.kmSource, due: r.due));
    }
    return _serviceFuture!;
  }

  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retry() => _guarded(() async {
        setState(() => _repairsStream = null);
      });

  void _selectVehicle(String? v) {
    setState(() {
      _vehicleNumber = v;
      _pinnedPartId = null;
      _hoveredPartId = null;
      _repairsStream = null;
      _serviceFuture = null;
    });
  }

  void _handleHover(String? id) {
    if (_hoveredPartId != id) setState(() => _hoveredPartId = id);
  }

  void _handleTap(String? id) {
    setState(() {
      if (id == null || _pinnedPartId == id) {
        _pinnedPartId = null;
      } else {
        _pinnedPartId = id;
      }
    });
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $code')),
    );
  }

  void _openHistory(String vehicleNumber) {
    pushWebAware(
      context,
      RepairHistoryScreen(
        prefillVehicleNumber: vehicleNumber,
        firestoreOverride: widget.firestoreOverride,
        currentUidOverride: widget.currentUidOverride,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _accessFuture,
      builder: (context, accessSnap) {
        if (accessSnap.connectionState != ConnectionState.done) {
          return const Scaffold(body: LoadingState());
        }
        if (accessSnap.data != true) {
          return const Scaffold(
            body: EmptyState(icon: Icons.lock_outline, title: 'NO ACCESS'),
          );
        }
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            title: const Text('Vehicle Health'),
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
          ),
          body: FutureBuilder<List<String>>(
            future: _vehiclesFuture,
            builder: (context, vehSnap) {
              if (vehSnap.connectionState != ConnectionState.done) {
                return const LoadingState();
              }
              final vehicles = vehSnap.data ?? const [];
              final vehicleNumber =
                  _vehicleNumber ?? (vehicles.isNotEmpty ? vehicles.first : null);
              if (vehicleNumber == null) {
                return const EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'NO COMPANY VEHICLES YET',
                );
              }
              return _buildBody(context, vehicles, vehicleNumber);
            },
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, List<String> vehicles, String vehicleNumber) {
    final activePartId = _pinnedPartId ?? _hoveredPartId;
    return LayoutBuilder(builder: (context, outer) {
      final isWide = outer.maxWidth >= 900;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<Map<String, String>>(
              future: _fleetStatusFuture,
              builder: (context, statusSnap) =>
                  _vehicleSelector(vehicles, vehicleNumber, statusSnap.data ?? const {}),
            ),
            const SizedBox(height: AppSpacing.md),
            _sectionHeader(vehicleNumber),
            const SizedBox(height: AppSpacing.xs),
            _VehicleKmLine(key: ValueKey(vehicleNumber), vehicleNumber: vehicleNumber, db: _db),
            const SizedBox(height: AppSpacing.sm),
            StreamBuilder<QuerySnapshot>(
              stream: _streamFor(vehicleNumber),
              builder: (context, snap) {
                if (snap.hasError) {
                  final err = snap.error;
                  return ErrorState(
                    message: err is TimeoutException
                        ? 'Taking too long — RETRY'
                        : 'Failed to load repairs: $err',
                    onRetry: _retry,
                  );
                }
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(AppSpacing.xl),
                    child: LoadingState(),
                  );
                }
                final docs =
                    snap.data!.docs.map((d) => d.data() as Map<String, dynamic>).toList();
                final summaries = summarizeRepairsByPart(docs);
                final redParts = <String>{};
                final amberParts = <String>{};
                final activeParts = <String>{};
                for (final id in kTruckPartIds) {
                  final s = summaries[id] ?? PartRepairSummary.empty;
                  if (s.openCount > 0) {
                    redParts.add(id);
                  } else if (s.pendingApprovalCount > 0) {
                    amberParts.add(id);
                  }
                  if (!s.isEmpty) activeParts.add(id);
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (docs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.sm),
                        child: EmptyState(
                          icon: Icons.verified_outlined,
                          title: 'NO REPAIRS FOR THIS TRUCK YET',
                          hint: 'ALL PARTS GREEN',
                        ),
                      ),
                    _legend(),
                    const SizedBox(height: AppSpacing.md),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _roadBackdrop(
                          child: TruckPartsMap(
                            highlightedPartId: activePartId,
                            redPartIds: redParts,
                            amberPartIds: amberParts,
                            activePartIds: activeParts,
                            onHover: _handleHover,
                            onTap: _handleTap,
                          ),
                        ),
                        if (isWide && activePartId != null)
                          _floatingDetailCard(
                            context,
                            activePartId,
                            summaries[activePartId] ?? PartRepairSummary.empty,
                            vehicleNumber,
                            outer.maxWidth,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _otherAndTyresRow(summaries, vehicleNumber, activePartId),
                    if (!isWide && activePartId != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      _detailPanel(
                        context,
                        activePartId,
                        summaries[activePartId] ?? PartRepairSummary.empty,
                        vehicleNumber,
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      );
    });
  }

  Widget _roadBackdrop({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.card, AppColors.primarySoft.withOpacity(0.5)],
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _vehicleSelector(
    List<String> vehicles,
    String vehicleNumber,
    Map<String, String> fleetStatus,
  ) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: vehicles.contains(vehicleNumber) ? vehicleNumber : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Vehicle',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.button)),
            ),
            items: vehicles
                .map((v) => DropdownMenuItem<String>(
                      value: v,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (fleetStatus.containsKey(v)) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _fleetDotColor(fleetStatus[v]!),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(v),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: _busy ? null : _selectVehicle,
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String vehicleNumber) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        Text('VEHICLE HEALTH', style: AppText.title),
        Text('— $vehicleNumber', style: AppText.section.copyWith(color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _legend() {
    Widget dot(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(label, style: AppText.caption),
          ],
        );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        dot(AppColors.danger, 'Open repairs'),
        dot(AppColors.warning, 'Pending approval'),
        dot(AppColors.success, 'OK'),
      ],
    );
  }

  Widget _otherAndTyresRow(
    Map<String, PartRepairSummary> summaries,
    String vehicleNumber,
    String? activePartId,
  ) {
    Widget chip(String id, String label, PartRepairSummary s) {
      final selected = activePartId == id;
      Color color;
      if (s.openCount > 0) {
        color = AppColors.danger;
      } else if (s.pendingApprovalCount > 0) {
        color = AppColors.warning;
      } else if (!s.isEmpty) {
        color = AppColors.success;
      } else {
        color = AppColors.textMuted;
      }
      return Semantics(
        button: true,
        label: '$label${s.openCount > 0 ? ', has open repairs' : ''}',
        child: ChoiceChip(
          label: Text(label),
          avatar: CircleAvatar(backgroundColor: color, radius: 6),
          selected: selected,
          onSelected: (_) => _handleTap(selected ? null : id),
        ),
      );
    }

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        chip('tyres', 'ALL TYRES', summaries['tyres'] ?? PartRepairSummary.empty),
        chip('__other__', 'OTHER / GENERAL', summaries['__other__'] ?? PartRepairSummary.empty),
      ],
    );
  }

  Widget _floatingDetailCard(
    BuildContext context,
    String partId,
    PartRepairSummary summary,
    String vehicleNumber,
    double containerWidth,
  ) {
    final geometry = buildTruckPartGeometry().firstWhere(
      (p) => p.id == partId,
      orElse: () => buildTruckPartGeometry().first,
    );
    // Approximate — positions relative to the outer container width using
    // the part's normalized (0..1) centroid; doesn't account for
    // BoxFit.contain letterboxing, which is an acceptable simplification
    // for a floating card that's already clamped on-screen.
    final left =
        (geometry.normalizedCentroid.dx * containerWidth).clamp(0, containerWidth - 320).toDouble();
    return Positioned(
      left: left,
      top: 0,
      width: 320,
      child: Material(
        color: Colors.transparent,
        child: _detailPanel(context, partId, summary, vehicleNumber),
      ),
    );
  }

  Widget _detailPanel(
    BuildContext context,
    String partId,
    PartRepairSummary summary,
    String vehicleNumber,
  ) {
    final label = partId == '__other__'
        ? 'Other / General'
        : (kTruckPartLabels[partId] ?? partId);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: AppText.section, softWrap: true)),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _handleTap(null),
                tooltip: 'Close',
              ),
            ],
          ),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: 4,
            children: [
              Text('Open: ${summary.openCount}', style: AppText.caption),
              Text('Pending approval: ${summary.pendingApprovalCount}', style: AppText.caption),
              Text('Completed: ${summary.completedCount}', style: AppText.caption),
            ],
          ),
          _servicePartStatus(partId),
          const SizedBox(height: AppSpacing.sm),
          if (summary.latestCodes.isEmpty)
            Text('No repairs logged against this part.', style: AppText.caption)
          else
            for (final r in summary.latestCodes) _codeRow(r),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _openHistory(vehicleNumber),
              child: const Text('VIEW ALL'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _servicePartStatus(String partId) {
    final vehicleNumber = _vehicleNumber ?? '';
    if (vehicleNumber.isEmpty) return const SizedBox.shrink();
    return FutureBuilder<({double? currentKm, String kmSource, List<ServiceItemDue> due})>(
      future: _serviceOverviewFor(vehicleNumber),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SizedBox(
              height: 12,
              width: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final due = snap.data?.due ?? const <ServiceItemDue>[];
        final matches = due
            .where((d) => servicePartKeywordMatch(d.itemName) == partId)
            .toList();
        if (matches.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final d in matches)
                StatusChip(status: _serviceStatusLabel(d.status)),
            ],
          ),
        );
      },
    );
  }

  String _serviceStatusLabel(String status) {
    switch (status) {
      case ServiceItemDueStatus.overdue:
      case ServiceItemDueStatus.missed:
        return 'SERVICE OVERDUE';
      case ServiceItemDueStatus.dueSoon:
        return 'SERVICE DUE SOON';
      case ServiceItemDueStatus.kmUnknown:
        return 'SERVICE KM UNKNOWN';
      default:
        return 'SERVICE OK';
    }
  }

  Widget _codeRow(Map<String, dynamic> r) {
    final code = (r['code'] ?? '').toString();
    final title = (r['description'] ?? '').toString();
    final status = (r['status'] ?? '').toString();
    final reportedAt = r['reportedAt'];
    final dateLabel = reportedAt is Timestamp
        ? '${reportedAt.toDate().year}-${reportedAt.toDate().month.toString().padLeft(2, '0')}-${reportedAt.toDate().day.toString().padLeft(2, '0')}'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onLongPress: () => _copyCode(code),
        onTap: () => _openHistory(_vehicleNumber ?? ''),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    code,
                    style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.4),
                    softWrap: true,
                  ),
                  Text(title, style: AppText.caption, softWrap: true),
                  if (dateLabel.isNotEmpty)
                    Text(dateLabel, style: AppText.caption.copyWith(color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Flexible(child: StatusChip(status: status)),
          ],
        ),
      ),
    );
  }
}
