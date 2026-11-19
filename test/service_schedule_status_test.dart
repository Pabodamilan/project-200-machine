// Unit tests for the SERVICE STATUS COLOURS + NOTIFICATIONS task's shared
// pure functions: computeScheduleStatus (the single RED/AMBER/GREEN +
// PROVISIONAL source of truth both the per-vehicle ServiceItemDue system
// and the fleet-wide ServiceAlert system now sit on top of),
// latestPendingOrReturnedRecord (which SUBMITTED/RETURNED record wins when
// a schedule has more than one non-approved record), and the small
// formatting/lookup helpers built alongside them (serviceItemStatusSummary,
// provisionalChipLabel/Color, serviceStatusHeadline, worstServiceDueAlertFor).
// No Firestore/widgets involved — plain values in, plain values out, same
// convention as the rest of this file's pure service-workflow functions.
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/app_theme.dart';
import 'package:project_200_machine/main.dart';

void main() {
  group('computeScheduleStatus', () {
    final now = DateTime(2026, 10, 27);

    test('RED: overdue past the milestone with no submitted/approved record', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        currentKm: 45800,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.overdue);
      expect(due.provisional, ServiceProvisionalState.none);
      expect(due.kmRemaining, equals(-800));
    });

    test('RED: MISSED a full interval past the milestone with no record', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        currentKm: 91000,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.missed);
    });

    test('AMBER: within warnBeforeKm of the next milestone', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        currentKm: 44500,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.dueSoon);
      expect(due.kmRemaining, equals(500));
    });

    test('GREEN: serviced and next milestone not yet within warn range', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: [
          {
            'vehicleNumber': 'WP-1111',
            'scheduleId': 'sched1',
            'milestoneKm': 45000.0,
            'doneKm': 45200.0,
            'serviceDate': DateTime(2026, 1, 1),
            'garageName': 'Acme Garage',
            'submittedByName': 'Mechanic Joe',
          },
        ],
        currentKm: 46000,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.ok);
      expect(due.provisional, ServiceProvisionalState.none);
      expect(due.milestoneKm, equals(90000));
      expect(due.lastDoneKm, equals(45200));
      expect(due.lastDoneDate, equals(DateTime(2026, 1, 1)));
      expect(due.lastGarageName, equals('Acme Garage'));
      expect(due.lastSubmitterName, equals('Mechanic Joe'));
    });

    test('next milestone after a LATE service is the next fixed multiple, not a '
        'sliding window from when it was actually done', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: [
          {
            'vehicleNumber': 'WP-1111',
            'scheduleId': 'sched1',
            // Done late, at 45,800 instead of exactly 45,000.
            'milestoneKm': 45000.0,
            'doneKm': 45800.0,
            'serviceDate': DateTime(2026, 1, 1),
          },
        ],
        currentKm: 89500,
        now: now,
      );
      // Next milestone is still the fixed 90,000 — not 45,800 + 45,000.
      expect(due.milestoneKm, equals(90000));
      expect(due.status, ServiceItemDueStatus.dueSoon);
      expect(due.kmRemaining, equals(500));
    });

    test('PROVISIONAL SUBMITTED overrides an otherwise-RED status to GREEN '
        '(clears immediately on submit, before management decides)', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        pendingOrReturned: {
          'status': ServiceRecordStatus.submitted,
          'submittedAt': DateTime(2026, 10, 26),
        },
        currentKm: 45800,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.ok);
      expect(due.provisional, ServiceProvisionalState.awaitingApproval);
    });

    test('PROVISIONAL RETURNED forces RED regardless of what the km math alone '
        'would say, and carries the return reason', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        pendingOrReturned: {
          'status': ServiceRecordStatus.returned,
          'returnedAt': DateTime(2026, 10, 26),
          'returnReason': 'Missing receipt',
        },
        // Well within range by km alone — would otherwise be OK.
        currentKm: 10000,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.overdue);
      expect(due.provisional, ServiceProvisionalState.returned);
      expect(due.returnReason, equals('Missing receipt'));
    });

    test('APPROVED is solid GREEN with no provisional chip', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: [
          {
            'vehicleNumber': 'WP-1111',
            'scheduleId': 'sched1',
            'milestoneKm': 45000.0,
            'doneKm': 45000.0,
            'serviceDate': DateTime(2026, 1, 1),
          },
        ],
        // The latest non-approved record for this schedule is an OLD
        // returned one that was since resubmitted and approved — it must
        // not still force RED once an APPROVED record exists for it.
        pendingOrReturned: null,
        currentKm: 46000,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.ok);
      expect(due.provisional, ServiceProvisionalState.none);
    });

    test('KM UNKNOWN: unknown current km never fakes red or green', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: '45,000 km Service',
        intervalKm: 45000,
        warnBeforeKm: 1000,
        approvedRecords: const [],
        currentKm: null,
        now: now,
      );
      expect(due.status, ServiceItemDueStatus.kmUnknown);
      expect(due.kmRemaining, isNull);
    });

    test('KM UNKNOWN does not suppress a genuine days-based overdue finding', () {
      final due = computeScheduleStatus(
        scheduleId: 'sched1',
        scheduleName: 'Annual Inspection',
        intervalKm: 45000,
        intervalDays: 365,
        warnBeforeKm: 1000,
        approvedRecords: [
          {
            'vehicleNumber': 'WP-1111',
            'scheduleId': 'sched1',
            'milestoneKm': 45000.0,
            'serviceDate': DateTime(2025, 1, 1),
          },
        ],
        currentKm: null,
        now: DateTime(2026, 6, 1),
      );
      expect(due.status, ServiceItemDueStatus.overdue);
    });
  });

  group('latestPendingOrReturnedRecord', () {
    test('null when there are no SUBMITTED/RETURNED records', () {
      expect(
        latestPendingOrReturnedRecord([
          {'status': ServiceRecordStatus.approved, 'serviceDate': DateTime(2026, 1, 1)},
        ]),
        isNull,
      );
    });

    test('picks SUBMITTED by submittedAt', () {
      final records = [
        {'status': ServiceRecordStatus.submitted, 'submittedAt': DateTime(2026, 1, 1), 'id': 'a'},
        {'status': ServiceRecordStatus.submitted, 'submittedAt': DateTime(2026, 5, 1), 'id': 'b'},
      ];
      expect(latestPendingOrReturnedRecord(records)!['id'], equals('b'));
    });

    test('picks RETURNED by returnedAt, falling back to submittedAt', () {
      final records = [
        {
          'status': ServiceRecordStatus.returned,
          'submittedAt': DateTime(2026, 1, 1),
          'returnedAt': DateTime(2026, 1, 2),
          'id': 'a',
        },
      ];
      expect(latestPendingOrReturnedRecord(records)!['id'], equals('a'));
    });

    test('ignores APPROVED records even if they are the most recent', () {
      final records = [
        {'status': ServiceRecordStatus.submitted, 'submittedAt': DateTime(2026, 1, 1), 'id': 'a'},
        {'status': ServiceRecordStatus.approved, 'serviceDate': DateTime(2026, 6, 1), 'id': 'b'},
      ];
      expect(latestPendingOrReturnedRecord(records)!['id'], equals('a'));
    });
  });

  group('serviceItemStatusSummary', () {
    test('OVERDUE includes the over-by km amount', () {
      final due = ServiceItemDue(
        itemId: 'i1',
        itemName: 'Service',
        status: ServiceItemDueStatus.overdue,
        kmRemaining: -800,
      );
      expect(serviceItemStatusSummary(due), equals('SERVICE OVERDUE 800 km'));
    });

    test('DUE SOON includes the remaining km amount', () {
      final due = ServiceItemDue(
        itemId: 'i1',
        itemName: 'Service',
        status: ServiceItemDueStatus.dueSoon,
        kmRemaining: 800,
      );
      expect(serviceItemStatusSummary(due), equals('DUE SOON 800 km'));
    });

    test('OK with history shows the last serviced date and next due km', () {
      final due = ServiceItemDue(
        itemId: 'i1',
        itemName: 'Service',
        status: ServiceItemDueStatus.ok,
        lastDoneDate: DateTime(2026, 1, 1),
        milestoneKm: 90000,
      );
      expect(serviceItemStatusSummary(due), equals('SERVICED 2026-01-01 - next at 90000 km'));
    });

    test('KM UNKNOWN is reported as such, not a km figure', () {
      final due = ServiceItemDue(
        itemId: 'i1',
        itemName: 'Service',
        status: ServiceItemDueStatus.kmUnknown,
      );
      expect(serviceItemStatusSummary(due), equals('KM UNKNOWN'));
    });
  });

  group('provisionalChipLabel / provisionalChipColor', () {
    test('AWAITING_APPROVAL label and green-ish color', () {
      expect(
        provisionalChipLabel(ServiceProvisionalState.awaitingApproval),
        equals('AWAITING APPROVAL'),
      );
      expect(provisionalChipColor(ServiceProvisionalState.awaitingApproval), equals(AppColors.success));
    });

    test('RETURNED label and red color', () {
      expect(
        provisionalChipLabel(ServiceProvisionalState.returned),
        equals('RETURNED - FIX AND RESUBMIT'),
      );
      expect(provisionalChipColor(ServiceProvisionalState.returned), equals(AppColors.danger));
    });

    test('NONE has no label', () {
      expect(provisionalChipLabel(ServiceProvisionalState.none), isNull);
    });
  });

  group('serviceStatusHeadline', () {
    test('a technical viewer sees a plain, self-focused RED label', () {
      expect(
        serviceStatusHeadline(ServiceItemDueStatus.overdue, forManagement: false),
        equals('SERVICE NOT DONE'),
      );
    });

    test('a management viewer sees who/what/how overdue for the same RED status', () {
      final headline = serviceStatusHeadline(
        ServiceItemDueStatus.overdue,
        forManagement: true,
        overByKm: 1200,
        lastSubmitterName: 'Mechanic Joe',
      );
      expect(headline, contains('NOT DONE BY TECHNICAL TEAM'));
      expect(headline, contains('1200 km overdue'));
      expect(headline, contains('last by Mechanic Joe'));
    });

    test('AMBER/GREEN read the same for both audiences', () {
      expect(
        serviceStatusHeadline(ServiceItemDueStatus.dueSoon, forManagement: false),
        equals(serviceStatusHeadline(ServiceItemDueStatus.dueSoon, forManagement: true)),
      );
    });
  });

  group('worstServiceDueAlertFor', () {
    test('picks the worst (MISSED beats OVERDUE beats DUE_SOON) for one vehicle', () {
      final alerts = [
        const ServiceAlert(
          kind: ServiceAlertKind.serviceDue,
          severity: ServiceAlertSeverity.dueSoon,
          audience: ServiceAlertAudience.both,
          vehicleNumber: 'WP-1111',
          title: 'A',
          detail: '',
        ),
        const ServiceAlert(
          kind: ServiceAlertKind.serviceDue,
          severity: ServiceAlertSeverity.missed,
          audience: ServiceAlertAudience.both,
          vehicleNumber: 'WP-1111',
          title: 'B',
          detail: '',
        ),
        const ServiceAlert(
          kind: ServiceAlertKind.serviceDue,
          severity: ServiceAlertSeverity.overdue,
          audience: ServiceAlertAudience.both,
          vehicleNumber: 'WP-2222',
          title: 'C',
          detail: '',
        ),
      ];
      expect(worstServiceDueAlertFor(alerts, 'WP-1111')!.title, equals('B'));
    });

    test('null when the vehicle has no serviceDue alert', () {
      final alerts = [
        const ServiceAlert(
          kind: ServiceAlertKind.serviceReturned,
          severity: ServiceAlertSeverity.overdue,
          audience: ServiceAlertAudience.mechanic,
          vehicleNumber: 'WP-1111',
          title: 'A',
          detail: '',
        ),
      ];
      expect(worstServiceDueAlertFor(alerts, 'WP-1111'), isNull);
      expect(worstServiceDueAlertFor(alerts, 'WP-9999'), isNull);
    });
  });
}
