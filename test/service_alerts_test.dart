// Unit tests for the RED ALERTS feature's pure functions:
// computeServiceAlerts (service-schedule due-ness, same math as
// computeNextMilestone/Service Overview) and the 5 "also include" alert
// builders (returned, submitted-pending, defect-pending, daily-check-low,
// daily-check-not-done), plus filterServiceAlertsForUser's
// audience/permission gate. No Firestore/widgets involved — every input
// here is a plain map/DateTime, matching the rest of this file's pure
// service-workflow functions (repair_workflow_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  group('computeServiceAlerts', () {
    final now = DateTime(2026, 10, 26);

    Map<String, dynamic> schedule({
      String id = 'sched1',
      String name = '45,000 km Service',
      double intervalKm = 45000,
      int? intervalDays,
      double warnBeforeKm = 1000,
      String appliesTo = 'ALL',
      List<String> vehicleNumbers = const [],
      bool active = true,
    }) =>
        {
          'id': id,
          'name': name,
          'intervalKm': intervalKm,
          'intervalDays': intervalDays,
          'warnBeforeKm': warnBeforeKm,
          'appliesTo': appliesTo,
          'vehicleNumbers': vehicleNumbers,
          'active': active,
        };

    Map<String, dynamic> vehicle(String truckNumber) => {'truckNumber': truckNumber};

    test('OK: well within the next milestone -> no alert', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule()],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 10000, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('DUE SOON: within warnBeforeKm of the milestone -> one DUE_SOON alert', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule()],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 44500, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, equals(ServiceAlertSeverity.dueSoon));
      expect(alerts.single.vehicleNumber, equals('WP-1111'));
      expect(alerts.single.scheduleId, equals('sched1'));
    });

    test('OVERDUE: just past the milestone -> one OVERDUE alert with overByKm', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule()],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 45800, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, equals(ServiceAlertSeverity.overdue));
      expect(alerts.single.overByKm, equals(800));
      expect(alerts.single.detail, equals('OVERDUE BY 800 km'));
    });

    test('MISSED: a full interval past the milestone with no approved record -> MISSED', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule()],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 91000, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, equals(ServiceAlertSeverity.missed));
    });

    test('never serviced: no approved records at all, km already past milestone 1 -> OVERDUE, '
        'not a crash / special case', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-2222')],
        schedules: [schedule()],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-2222': (km: 46000, source: 'last recorded service — no GPS, may be stale'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, equals(ServiceAlertSeverity.overdue));
      expect(alerts.single.lastServiceDate, isNull);
    });

    test('a completed milestone shifts the next due point, not a sliding window from when it '
        'was actually done', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule()],
        approvedRecords: [
          {
            'vehicleNumber': 'WP-1111',
            'scheduleId': 'sched1',
            'milestoneKm': 45000.0,
            'serviceDate': DateTime(2026, 1, 1),
            'submittedByName': 'Mechanic Joe',
          },
        ],
        kmByVehicle: {
          'WP-1111': (km: 46000, source: 'live GPS reading'),
        },
        now: now,
      );
      // Milestone 1 (45,000) is done -> next due point is 90,000, not
      // overdue yet at 46,000 km.
      expect(alerts, isEmpty);
    });

    test('unknown km with a km-based schedule -> one amber KM_UNKNOWN alert, not red, '
        'and not one per schedule', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-3333')],
        schedules: [
          schedule(id: 's1', name: 'Schedule A'),
          schedule(id: 's2', name: 'Schedule B'),
        ],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-3333': (km: null, source: 'unknown — no GPS and no service history yet'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.severity, equals(ServiceAlertSeverity.kmUnknown));
      expect(alerts.single.detail, equals('KM UNKNOWN — ENTER KM'));
      expect(alerts.single.severity, isNot(equals(ServiceAlertSeverity.overdue)));
    });

    test('unknown km with NO km-based schedule -> no KM_UNKNOWN alert (nothing to evaluate)', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-4444')],
        schedules: const [],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-4444': (km: null, source: 'unknown — no GPS and no service history yet'),
        },
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('days-interval schedule: overdue by elapsed days even though km has not reached the '
        'milestone', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-5555')],
        schedules: [schedule(id: 's1', intervalKm: 100000, intervalDays: 90)],
        approvedRecords: [
          {
            'vehicleNumber': 'WP-5555',
            'scheduleId': 's1',
            'milestoneKm': 0.0, // not a real milestone row; just exercises
                                 // the "lastServiceDate" lookup path below
          },
        ],
        kmByVehicle: {
          'WP-5555': (km: 5000, source: 'live GPS reading'),
        },
        now: now,
      );
      // No approved record actually matches (milestoneKm 0 rounds to
      // milestone 0, never "completed" in the 1-based numbering), so this
      // is really the never-serviced + far-from-due-km case: intervalDays
      // only escalates when status is otherwise OK AND a
      // lastApprovedDoneDate exists, so with none recorded here it stays
      // OK. Rerun with a genuine lastServiceDate to prove the days path:
      expect(alerts, isEmpty);

      final alertsWithDate = computeServiceAlerts(
        vehicles: [vehicle('WP-5555')],
        schedules: [schedule(id: 's1', intervalKm: 100000, intervalDays: 90)],
        approvedRecords: [
          {
            'vehicleNumber': 'WP-5555',
            'scheduleId': 's1',
            'milestoneKm': 100000.0,
            'serviceDate': now.subtract(const Duration(days: 120)),
          },
        ],
        kmByVehicle: {
          'WP-5555': (km: 5000, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alertsWithDate, hasLength(1));
      expect(alertsWithDate.single.severity, equals(ServiceAlertSeverity.overdue));
    });

    test('appliesTo SELECTED only matches listed vehicle numbers', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111'), vehicle('WP-9999')],
        schedules: [
          schedule(appliesTo: 'SELECTED', vehicleNumbers: const ['WP-1111']),
        ],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 46000, source: 'live GPS reading'),
          'WP-9999': (km: 46000, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.vehicleNumber, equals('WP-1111'));
    });

    test('inactive schedules are skipped entirely', () {
      final alerts = computeServiceAlerts(
        vehicles: [vehicle('WP-1111')],
        schedules: [schedule(active: false)],
        approvedRecords: const [],
        kmByVehicle: {
          'WP-1111': (km: 99999, source: 'live GPS reading'),
        },
        now: now,
      );
      expect(alerts, isEmpty);
    });
  });

  group('serviceReturnedAlerts', () {
    test('a RETURNED record produces one MECHANIC alert with the reason', () {
      final alerts = serviceReturnedAlerts([
        {
          'id': 'rec1',
          'vehicleNumber': 'WP-1111',
          'status': 'RETURNED',
          'returnReason': 'MISSING PHOTOS',
          'returnedAt': DateTime(2026, 10, 25),
        },
      ]);
      expect(alerts, hasLength(1));
      expect(alerts.single.audience, equals(ServiceAlertAudience.mechanic));
      expect(alerts.single.detail, contains('MISSING PHOTOS'));
    });

    test('a SUBMITTED or APPROVED record produces no alert', () {
      final alerts = serviceReturnedAlerts([
        {'vehicleNumber': 'WP-1111', 'status': 'SUBMITTED'},
        {'vehicleNumber': 'WP-2222', 'status': 'APPROVED'},
      ]);
      expect(alerts, isEmpty);
    });
  });

  group('serviceSubmittedPendingAlerts', () {
    final now = DateTime(2026, 10, 26, 12);

    test('submitted more than 24h ago -> MANAGEMENT alert', () {
      final alerts = serviceSubmittedPendingAlerts(
        [
          {
            'id': 'rec1',
            'vehicleNumber': 'WP-1111',
            'status': 'SUBMITTED',
            'submittedAt': now.subtract(const Duration(hours: 30)),
            'submittedByName': 'Mechanic Joe',
          },
        ],
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.audience, equals(ServiceAlertAudience.management));
      expect(alerts.single.detail, equals('Waiting 30h for approval'));
    });

    test('submitted less than 24h ago -> no alert yet', () {
      final alerts = serviceSubmittedPendingAlerts(
        [
          {
            'vehicleNumber': 'WP-1111',
            'status': 'SUBMITTED',
            'submittedAt': now.subtract(const Duration(hours: 2)),
          },
        ],
        now: now,
      );
      expect(alerts, isEmpty);
    });
  });

  group('defectPendingAlerts', () {
    final now = DateTime(2026, 10, 26, 12);

    test('OPEN, no repair job, reported >24h ago -> MECHANIC alert', () {
      final alerts = defectPendingAlerts(
        [
          {
            'id': 'def1',
            'vehicleNumber': 'WP-1111',
            'status': 'OPEN',
            'repairJobId': null,
            'reportedAt': now.subtract(const Duration(hours: 48)),
          },
        ],
        now: now,
      );
      expect(alerts, hasLength(1));
      expect(alerts.single.audience, equals(ServiceAlertAudience.mechanic));
    });

    test('already linked to a repair job -> no alert even if OPEN and old', () {
      final alerts = defectPendingAlerts(
        [
          {
            'vehicleNumber': 'WP-1111',
            'status': 'OPEN',
            'repairJobId': 'job1',
            'reportedAt': now.subtract(const Duration(hours: 48)),
          },
        ],
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('REJECTED -> no alert', () {
      final alerts = defectPendingAlerts(
        [
          {
            'vehicleNumber': 'WP-1111',
            'status': 'REJECTED',
            'reportedAt': now.subtract(const Duration(hours: 48)),
          },
        ],
        now: now,
      );
      expect(alerts, isEmpty);
    });
  });

  group('dailyCheckLowAlerts', () {
    test('hasLow true -> one MANAGEMENT alert per doc', () {
      final alerts = dailyCheckLowAlerts([
        {'id': 'dc1', 'vehicleNumber': 'WP-1111', 'hasLow': true},
        {'id': 'dc2', 'vehicleNumber': 'WP-2222', 'hasLow': false},
      ]);
      expect(alerts, hasLength(1));
      expect(alerts.single.vehicleNumber, equals('WP-1111'));
      expect(alerts.single.audience, equals(ServiceAlertAudience.management));
    });
  });

  group('dailyCheckNotDoneAlerts', () {
    test('each not-checked vehicle produces one MANAGEMENT alert', () {
      final alerts = dailyCheckNotDoneAlerts([
        (vehicleNumber: 'WP-1111', driverName: 'Driver Dan'),
      ]);
      expect(alerts, hasLength(1));
      expect(alerts.single.audience, equals(ServiceAlertAudience.management));
      expect(alerts.single.detail, contains('Driver Dan'));
    });
  });

  group('filterServiceAlertsForUser', () {
    final mechanicAlert = const ServiceAlert(
      kind: ServiceAlertKind.serviceReturned,
      severity: ServiceAlertSeverity.info,
      audience: ServiceAlertAudience.mechanic,
      vehicleNumber: 'WP-1111',
      title: 'x',
      detail: 'x',
    );
    final managementAlert = const ServiceAlert(
      kind: ServiceAlertKind.dailyCheckLow,
      severity: ServiceAlertSeverity.info,
      audience: ServiceAlertAudience.management,
      vehicleNumber: 'WP-1111',
      title: 'x',
      detail: 'x',
    );
    final bothAlert = const ServiceAlert(
      kind: ServiceAlertKind.serviceDue,
      severity: ServiceAlertSeverity.overdue,
      audience: ServiceAlertAudience.both,
      vehicleNumber: 'WP-1111',
      title: 'x',
      detail: 'x',
    );

    test('admin/owner sees everything', () {
      final result = filterServiceAlertsForUser(
        [mechanicAlert, managementAlert, bothAlert],
        isAdminOrOwner: true,
        hasServiceDo: false,
        hasServiceApprove: false,
        hasServiceView: false,
        hasDiagnose: false,
      );
      expect(result, hasLength(3));
    });

    test('SERVICE_DO only sees mechanic + both, not management', () {
      final result = filterServiceAlertsForUser(
        [mechanicAlert, managementAlert, bothAlert],
        isAdminOrOwner: false,
        hasServiceDo: true,
        hasServiceApprove: false,
        hasServiceView: false,
        hasDiagnose: false,
      );
      expect(result, containsAll([mechanicAlert, bothAlert]));
      expect(result, isNot(contains(managementAlert)));
    });

    test('SERVICE_VIEW only sees management + both, not mechanic', () {
      final result = filterServiceAlertsForUser(
        [mechanicAlert, managementAlert, bothAlert],
        isAdminOrOwner: false,
        hasServiceDo: false,
        hasServiceApprove: false,
        hasServiceView: true,
        hasDiagnose: false,
      );
      expect(result, containsAll([managementAlert, bothAlert]));
      expect(result, isNot(contains(mechanicAlert)));
    });

    test('DIAGNOSE counts as mechanic audience', () {
      final result = filterServiceAlertsForUser(
        [mechanicAlert],
        isAdminOrOwner: false,
        hasServiceDo: false,
        hasServiceApprove: false,
        hasServiceView: false,
        hasDiagnose: true,
      );
      expect(result, hasLength(1));
    });

    test('no qualifying permission -> sees nothing', () {
      final result = filterServiceAlertsForUser(
        [mechanicAlert, managementAlert, bothAlert],
        isAdminOrOwner: false,
        hasServiceDo: false,
        hasServiceApprove: false,
        hasServiceView: false,
        hasDiagnose: false,
      );
      expect(result, isEmpty);
    });
  });
}
