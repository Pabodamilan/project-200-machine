// Unit tests for the new Truck Repair v2 pure functions (Step 1 of the
// rebuild): buildRepairCode (per-category-per-year reset, padding, prefix),
// hasOpenDuplicateRepair, canTechnicalSetRepairStatus/
// canManagementSetRepairStatus (status transition guards), and
// computeRepairListProgress (list doneCount/ALL_DONE calc). Also exercises
// nextRepairCode end-to-end against FakeFirebaseFirestore to confirm the
// counters/repair_{CAT}_{yy} transaction actually increments/resets
// correctly, not just the pure formatting function.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  group('buildRepairCode', () {
    test('formats prefix/CAT/yyNNNN with zero-padded running number', () {
      expect(
        buildRepairCode(
          companyPrefix: 'NOD',
          categoryCode: 'ENG',
          year: 2026,
          runningNumber: 1,
        ),
        'NOD/ENG/260001',
      );
    });

    test('pads up to 4 digits but does not truncate a 5-digit running number', () {
      expect(
        buildRepairCode(
          companyPrefix: 'NOD',
          categoryCode: 'BRK',
          year: 2026,
          runningNumber: 12345,
        ),
        'NOD/BRK/2612345',
      );
    });

    test('uses a different company prefix verbatim', () {
      expect(
        buildRepairCode(
          companyPrefix: 'ACME',
          categoryCode: 'TYR',
          year: 2027,
          runningNumber: 7,
        ),
        'ACME/TYR/270007',
      );
    });

    test('takes only the last two digits of the year', () {
      expect(
        buildRepairCode(
          companyPrefix: 'NOD',
          categoryCode: 'OTH',
          year: 2099,
          runningNumber: 1,
        ),
        'NOD/OTH/990001',
      );
    });
  });

  group('repairCounterId', () {
    test('builds repair_{CAT}_{yy}', () {
      expect(repairCounterId('ENG', 2026), 'repair_ENG_26');
    });
  });

  group('nextRepairCode (transaction, FakeFirebaseFirestore)', () {
    test('running number increments per category per year', () async {
      final db = FakeFirebaseFirestore();
      final c1 = await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'ENG',
        now: DateTime(2026, 1, 1),
      );
      final c2 = await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'ENG',
        now: DateTime(2026, 6, 1),
      );
      expect(c1, 'NOD/ENG/260001');
      expect(c2, 'NOD/ENG/260002');
    });

    test('a different category starts its own running number at 1', () async {
      final db = FakeFirebaseFirestore();
      await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'ENG',
        now: DateTime(2026, 1, 1),
      );
      final brk = await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'BRK',
        now: DateTime(2026, 1, 1),
      );
      expect(brk, 'NOD/BRK/260001');
    });

    test('a new year resets the running number back to 1 for the same category', () async {
      final db = FakeFirebaseFirestore();
      final y2026 = await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'ENG',
        now: DateTime(2026, 12, 31),
      );
      final y2027 = await nextRepairCode(
        db: db,
        companyPrefix: 'NOD',
        categoryCode: 'ENG',
        now: DateTime(2027, 1, 1),
      );
      expect(y2026, 'NOD/ENG/260001');
      expect(y2027, 'NOD/ENG/270001');
    });
  });

  group('hasOpenDuplicateRepair', () {
    test('true when an open repair exists for the same vehicle+category', () {
      final existing = [
        {'vehicleNumber': 'WP-1234', 'categoryCode': 'ENG', 'status': RepairItemStatus.listed},
      ];
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: existing,
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isTrue,
      );
    });

    test('false when the only match is COMPLETED', () {
      final existing = [
        {'vehicleNumber': 'WP-1234', 'categoryCode': 'ENG', 'status': RepairItemStatus.completed},
      ];
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: existing,
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isFalse,
      );
    });

    test('false when the only match is REJECTED', () {
      final existing = [
        {'vehicleNumber': 'WP-1234', 'categoryCode': 'ENG', 'status': RepairItemStatus.rejected},
      ];
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: existing,
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isFalse,
      );
    });

    test('false when the vehicle matches but the category does not', () {
      final existing = [
        {'vehicleNumber': 'WP-1234', 'categoryCode': 'BRK', 'status': RepairItemStatus.reported},
      ];
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: existing,
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isFalse,
      );
    });

    test('false when the category matches but the vehicle does not', () {
      final existing = [
        {'vehicleNumber': 'WP-9999', 'categoryCode': 'ENG', 'status': RepairItemStatus.reported},
      ];
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: existing,
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isFalse,
      );
    });

    test('false with no existing repairs at all', () {
      expect(
        hasOpenDuplicateRepair(
          existingRepairs: const [],
          vehicleNumber: 'WP-1234',
          categoryCode: 'ENG',
        ),
        isFalse,
      );
    });
  });

  group('canTechnicalSetRepairStatus — status transition guards', () {
    test('LISTED -> IN_PROGRESS allowed (start)', () {
      expect(
        canTechnicalSetRepairStatus(RepairItemStatus.listed, RepairItemStatus.inProgress),
        isTrue,
      );
    });

    test('RETURNED -> IN_PROGRESS allowed (restart after rework)', () {
      expect(
        canTechnicalSetRepairStatus(RepairItemStatus.returned, RepairItemStatus.inProgress),
        isTrue,
      );
    });

    test('IN_PROGRESS -> DONE_PENDING_APPROVAL allowed (mark done)', () {
      expect(
        canTechnicalSetRepairStatus(
          RepairItemStatus.inProgress,
          RepairItemStatus.donePendingApproval,
        ),
        isTrue,
      );
    });

    test('REPORTED -> IN_PROGRESS NOT allowed (not yet listed by management)', () {
      expect(
        canTechnicalSetRepairStatus(RepairItemStatus.reported, RepairItemStatus.inProgress),
        isFalse,
      );
    });

    test('LISTED -> COMPLETED NOT allowed (technical cannot approve)', () {
      expect(
        canTechnicalSetRepairStatus(RepairItemStatus.listed, RepairItemStatus.completed),
        isFalse,
      );
    });

    test('LISTED -> REJECTED NOT allowed (technical cannot reject)', () {
      expect(
        canTechnicalSetRepairStatus(RepairItemStatus.listed, RepairItemStatus.rejected),
        isFalse,
      );
    });

    test('DONE_PENDING_APPROVAL -> IN_PROGRESS NOT allowed (not technical\'s to move once submitted)',
        () {
      expect(
        canTechnicalSetRepairStatus(
          RepairItemStatus.donePendingApproval,
          RepairItemStatus.inProgress,
        ),
        isFalse,
      );
    });
  });

  group('canManagementSetRepairStatus — status transition guards', () {
    test('can set LISTED', () {
      expect(
        canManagementSetRepairStatus(RepairItemStatus.reported, RepairItemStatus.listed),
        isTrue,
      );
    });

    test('can set REJECTED', () {
      expect(
        canManagementSetRepairStatus(RepairItemStatus.reported, RepairItemStatus.rejected),
        isTrue,
      );
    });

    test('can set RETURNED', () {
      expect(
        canManagementSetRepairStatus(
          RepairItemStatus.donePendingApproval,
          RepairItemStatus.returned,
        ),
        isTrue,
      );
    });

    test('can set COMPLETED', () {
      expect(
        canManagementSetRepairStatus(
          RepairItemStatus.donePendingApproval,
          RepairItemStatus.completed,
        ),
        isTrue,
      );
    });

    test('can set REPORTED (rule symmetry, even though no screen in this build uses it)', () {
      expect(
        canManagementSetRepairStatus(RepairItemStatus.listed, RepairItemStatus.reported),
        isTrue,
      );
    });

    test('cannot set IN_PROGRESS (that is technical\'s to set)', () {
      expect(
        canManagementSetRepairStatus(RepairItemStatus.listed, RepairItemStatus.inProgress),
        isFalse,
      );
    });

    test('cannot set DONE_PENDING_APPROVAL (that is technical\'s to set)', () {
      expect(
        canManagementSetRepairStatus(
          RepairItemStatus.inProgress,
          RepairItemStatus.donePendingApproval,
        ),
        isFalse,
      );
    });
  });

  group('repairCategoryForDailyCheckId', () {
    test('water_level -> COL', () {
      expect(repairCategoryForDailyCheckId('water_level'), 'COL');
    });

    test('engine_oil_level -> ENG', () {
      expect(repairCategoryForDailyCheckId('engine_oil_level'), 'ENG');
    });

    test('hydraulic_oil_level -> HYD', () {
      expect(repairCategoryForDailyCheckId('hydraulic_oil_level'), 'HYD');
    });

    test('an unknown id returns null rather than guessing', () {
      expect(repairCategoryForDailyCheckId('tyre_pressure'), isNull);
    });
  });

  group('computeRepairListProgress — list building', () {
    test('empty item list stays SUBMITTED with doneCount 0', () {
      final result = computeRepairListProgress(const []);
      expect(result.status, RepairListStatus.submitted);
      expect(result.doneCount, 0);
    });

    test('some items still in progress -> SUBMITTED with a partial doneCount', () {
      final result = computeRepairListProgress([
        RepairItemStatus.donePendingApproval,
        RepairItemStatus.inProgress,
        RepairItemStatus.listed,
      ]);
      expect(result.status, RepairListStatus.submitted);
      expect(result.doneCount, 1);
    });

    test('every item DONE_PENDING_APPROVAL -> ALL_DONE', () {
      final result = computeRepairListProgress([
        RepairItemStatus.donePendingApproval,
        RepairItemStatus.donePendingApproval,
      ]);
      expect(result.status, RepairListStatus.allDone);
      expect(result.doneCount, 2);
    });

    test('a mix of COMPLETED/REJECTED/DONE_PENDING_APPROVAL all count as done -> ALL_DONE', () {
      final result = computeRepairListProgress([
        RepairItemStatus.completed,
        RepairItemStatus.rejected,
        RepairItemStatus.donePendingApproval,
      ]);
      expect(result.status, RepairListStatus.allDone);
      expect(result.doneCount, 3);
    });

    test('a RETURNED item is not done -> stays SUBMITTED even if everything else is done', () {
      final result = computeRepairListProgress([
        RepairItemStatus.completed,
        RepairItemStatus.returned,
      ]);
      expect(result.status, RepairListStatus.submitted);
      expect(result.doneCount, 1);
    });
  });
}
