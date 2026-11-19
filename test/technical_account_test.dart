// Unit tests for the TECHNICAL account type's pure functions:
// technicalDefaults() (the pre-filled, still-editable defaults for a new
// Technical account / the "APPLY TECHNICAL DEFAULTS" button),
// resolveUserLandingKind() (the exact routing decision AuthGate makes —
// this is the real logic, not a parallel copy, so these tests are
// exercising production behavior), and resolveTechnicalHomeTiles() (which
// tiles TechnicalHomeScreen shows for a given set of permissions). No
// Firestore/widgets involved — plain values in, plain values out, same
// convention as the rest of this file's pure service-workflow functions.
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  group('technicalDefaults', () {
    test('grants Garage + Warehouse access and the TECHNICAL preset '
        '(REPAIR_WORK, HISTORY_VIEW, SERVICE_DO, SERVICE_VIEW)', () {
      final defaults = technicalDefaults();
      expect(defaults.canAccessGarage, isTrue);
      expect(defaults.canAccessWarehouse, isTrue);
      expect(
        defaults.repairPermissions.toSet(),
        equals({
          kPermRepairWork,
          kPermHistoryView,
          kPermServiceDo,
          kPermServiceView,
        }),
      );
    });

    test('never includes an approval/payments/settings permission by '
        'default', () {
      final defaults = technicalDefaults();
      expect(defaults.repairPermissions, isNot(contains(kPermApprove)));
      expect(defaults.repairPermissions, isNot(contains(kPermServiceApprove)));
      expect(defaults.repairPermissions, isNot(contains(kPermInvoices)));
      expect(defaults.repairPermissions, isNot(contains(kPermPayments)));
      expect(defaults.repairPermissions, isNot(contains(kPermRepairSettings)));
    });

    test('matches the TECHNICAL preset exactly (same source of truth as '
        'the checkbox grid\'s preset button)', () {
      expect(
        technicalDefaults().repairPermissions,
        equals(kRepairPermPresets['TECHNICAL']),
      );
    });
  });

  group('resolveUserLandingKind', () {
    test('role technical -> TECHNICAL_HOME regardless of Garage/Warehouse '
        'flags', () {
      expect(
        resolveUserLandingKind(
          role: 'technical',
          canAccessGarage: true,
          canAccessWarehouse: true,
        ),
        equals(UserLandingKind.technicalHome),
      );
      expect(
        resolveUserLandingKind(
          role: 'technical',
          canAccessGarage: false,
          canAccessWarehouse: false,
        ),
        equals(UserLandingKind.technicalHome),
      );
    });

    test('a non-technical role with both Garage + Warehouse -> the legacy '
        'TechnicianDashboard override, unchanged for existing users', () {
      expect(
        resolveUserLandingKind(
          role: 'supervisor',
          canAccessGarage: true,
          canAccessWarehouse: true,
        ),
        equals(UserLandingKind.technicianDashboard),
      );
    });

    test('a non-technical role with only Garage -> GARAGE_ONLY', () {
      expect(
        resolveUserLandingKind(
          role: 'field_worker',
          canAccessGarage: true,
          canAccessWarehouse: false,
        ),
        equals(UserLandingKind.garageOnly),
      );
    });

    test('a non-technical role with only Warehouse -> WAREHOUSE_ONLY', () {
      expect(
        resolveUserLandingKind(
          role: 'driver',
          canAccessGarage: false,
          canAccessWarehouse: true,
        ),
        equals(UserLandingKind.warehouseOnly),
      );
    });

    test('admin/owner/management with both flags -> NORMAL_ROLE_DASHBOARD, '
        'never the override (unchanged behavior for those roles)', () {
      for (final role in ['admin', 'owner', 'management']) {
        expect(
          resolveUserLandingKind(
            role: role,
            canAccessGarage: true,
            canAccessWarehouse: true,
          ),
          equals(UserLandingKind.normalRoleDashboard),
          reason: 'role=$role',
        );
      }
    });

    test('a plain role with neither flag -> NORMAL_ROLE_DASHBOARD', () {
      expect(
        resolveUserLandingKind(
          role: 'supervisor',
          canAccessGarage: false,
          canAccessWarehouse: false,
        ),
        equals(UserLandingKind.normalRoleDashboard),
      );
    });
  });

  group('resolveTechnicalHomeTiles', () {
    test('every flag true -> all 4 tiles, in a stable order', () {
      final tiles = resolveTechnicalHomeTiles(
        canAccessGarage: true,
        hasRepairWork: true,
        hasServiceView: true,
        canAccessWarehouse: true,
      );
      expect(
        tiles,
        equals([
          TechnicalHomeTile.vehicleMaintenance,
          TechnicalHomeTile.repairsToDo,
          TechnicalHomeTile.dailyChecks,
          TechnicalHomeTile.warehouse,
        ]),
      );
    });

    test('every flag false -> no tiles', () {
      expect(
        resolveTechnicalHomeTiles(
          canAccessGarage: false,
          hasRepairWork: false,
          hasServiceView: false,
          canAccessWarehouse: false,
        ),
        isEmpty,
      );
    });

    test('an admin unticking SERVICE_VIEW (but keeping everything else) '
        'only drops the Daily Checks tile', () {
      final tiles = resolveTechnicalHomeTiles(
        canAccessGarage: true,
        hasRepairWork: true,
        hasServiceView: false,
        canAccessWarehouse: true,
      );
      expect(tiles, isNot(contains(TechnicalHomeTile.dailyChecks)));
      expect(tiles, contains(TechnicalHomeTile.vehicleMaintenance));
      expect(tiles, contains(TechnicalHomeTile.repairsToDo));
      expect(tiles, contains(TechnicalHomeTile.warehouse));
    });

    test('REPORT_DEFECT alone (no REPAIR_WORK) does not show Repairs To Do '
        '— an inspector-only account would otherwise dead-end on tap', () {
      final tiles = resolveTechnicalHomeTiles(
        canAccessGarage: false,
        hasRepairWork: false,
        hasServiceView: false,
        canAccessWarehouse: false,
      );
      expect(tiles, isNot(contains(TechnicalHomeTile.repairsToDo)));
    });

    test('only Warehouse access -> only the Warehouse tile', () {
      expect(
        resolveTechnicalHomeTiles(
          canAccessGarage: false,
          hasRepairWork: false,
          hasServiceView: false,
          canAccessWarehouse: true,
        ),
        equals([TechnicalHomeTile.warehouse]),
      );
    });
  });
}
