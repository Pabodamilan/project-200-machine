// Unit tests for the pure Truck Repair workflow transition functions in
// lib/main.dart (RepairStatus/QuotationStatus/ApprovalDecision constants,
// canVerifyQuotation, canRequestApproval, canDecideApproval,
// isApprovalVisibleForLevel, isMultiQuotationThresholdMet,
// isInvoicePaymentBlocked, canCloseRepairJob, nextStepFor). These are pure
// functions over plain maps — no Firebase/widget setup needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  group('canVerifyQuotation', () {
    final quotation = {'status': QuotationStatus.submitted, 'enteredBy': 'uidA'};

    test('multi-user, Test Mode OFF: different person can verify', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: true,
          hasVerifyPerm: true,
          currentUid: 'uidB',
          mechanicalSupervisorId: 'uidC',
          testMode: false,
        ),
        isTrue,
      );
    });

    test('multi-user, Test Mode OFF: same person as enterer is blocked', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: true,
          hasVerifyPerm: true,
          currentUid: 'uidA',
          mechanicalSupervisorId: 'uidC',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('multi-user, Test Mode OFF: same person as diagnoser is blocked', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: true,
          hasVerifyPerm: true,
          currentUid: 'uidC',
          mechanicalSupervisorId: 'uidC',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('single-user, Test Mode ON: same person as enterer is allowed', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: true,
          hasVerifyPerm: true,
          currentUid: 'uidA',
          mechanicalSupervisorId: 'uidA',
          testMode: true,
        ),
        isTrue,
      );
    });

    test('missing permission always blocks, even in Test Mode', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: true,
          hasVerifyPerm: false,
          currentUid: 'uidB',
          testMode: true,
        ),
        isFalse,
      );
    });

    test('not selected blocks regardless of status', () {
      expect(
        canVerifyQuotation(
          quotation: quotation,
          isSelected: false,
          hasVerifyPerm: true,
          currentUid: 'uidB',
          testMode: true,
        ),
        isFalse,
      );
    });

    test('wrong status (already VERIFIED) blocks', () {
      expect(
        canVerifyQuotation(
          quotation: {'status': QuotationStatus.verified, 'enteredBy': 'uidA'},
          isSelected: true,
          hasVerifyPerm: true,
          currentUid: 'uidB',
          testMode: true,
        ),
        isFalse,
      );
    });
  });

  group('canRequestApproval', () {
    test('selected + VERIFIED + job VERIFIED + perm => true', () {
      expect(
        canRequestApproval(
          quotation: {'status': QuotationStatus.verified},
          isSelected: true,
          jobRepairStatus: RepairStatus.verified,
          hasRequestApprovalPerm: true,
        ),
        isTrue,
      );
    });

    test('job not yet VERIFIED => false', () {
      expect(
        canRequestApproval(
          quotation: {'status': QuotationStatus.verified},
          isSelected: true,
          jobRepairStatus: RepairStatus.quoting,
          hasRequestApprovalPerm: true,
        ),
        isFalse,
      );
    });

    test('missing permission => false', () {
      expect(
        canRequestApproval(
          quotation: {'status': QuotationStatus.verified},
          isSelected: true,
          jobRepairStatus: RepairStatus.verified,
          hasRequestApprovalPerm: false,
        ),
        isFalse,
      );
    });
  });

  group('canDecideApproval', () {
    final pendingApproval = {
      'decision': ApprovalDecision.pending,
      'requiredLevel': 'MANAGER',
      'requestedBy': 'uidR',
    };

    test('admin/owner, multi-user Test Mode OFF: different person decides', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: true,
          hasApprovePerm: false,
          currentUid: 'uidDecider',
          quotationEnteredBy: 'uidA',
          quotationVerifiedBy: 'uidB',
          testMode: false,
        ),
        isTrue,
      );
    });

    test('manager with APPROVE perm at MANAGER level can decide', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: false,
          hasApprovePerm: true,
          currentUid: 'uidDecider',
          quotationEnteredBy: 'uidA',
          quotationVerifiedBy: 'uidB',
          testMode: false,
        ),
        isTrue,
      );
    });

    test('manager without APPROVE perm cannot decide', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: false,
          hasApprovePerm: false,
          currentUid: 'uidDecider',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('manager at OWNER-level requirement cannot decide', () {
      expect(
        canDecideApproval(
          approval: {...pendingApproval, 'requiredLevel': 'OWNER'},
          isAdminOrOwner: false,
          hasApprovePerm: true,
          currentUid: 'uidDecider',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('multi-user Test Mode OFF: requester cannot decide their own request', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: true,
          hasApprovePerm: false,
          currentUid: 'uidR',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('multi-user Test Mode OFF: enterer cannot decide', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: true,
          hasApprovePerm: false,
          currentUid: 'uidA',
          quotationEnteredBy: 'uidA',
          testMode: false,
        ),
        isFalse,
      );
    });

    test('single-user Test Mode ON: same person as requester can decide', () {
      expect(
        canDecideApproval(
          approval: pendingApproval,
          isAdminOrOwner: true,
          hasApprovePerm: false,
          currentUid: 'uidR',
          testMode: true,
        ),
        isTrue,
      );
    });

    test('already decided (not PENDING) => false even for admin', () {
      expect(
        canDecideApproval(
          approval: {...pendingApproval, 'decision': ApprovalDecision.approved},
          isAdminOrOwner: true,
          hasApprovePerm: false,
          currentUid: 'uidDecider',
          testMode: true,
        ),
        isFalse,
      );
    });

    test('works the same for an ADDITIONAL_COST-shaped approval', () {
      final additionalCost = {
        'decision': ApprovalDecision.pending,
        'requiredLevel': 'MANAGER',
        'requestedBy': 'uidR',
        'approvalType': 'ADDITIONAL_COST',
      };
      expect(
        canDecideApproval(
          approval: additionalCost,
          isAdminOrOwner: false,
          hasApprovePerm: true,
          currentUid: 'uidDecider',
          testMode: false,
        ),
        isTrue,
      );
      expect(
        canDecideApproval(
          approval: additionalCost,
          isAdminOrOwner: false,
          hasApprovePerm: true,
          currentUid: 'uidR',
          testMode: false,
        ),
        isFalse,
      );
    });
  });

  group('isPaymentAmountValid (partial / over payment)', () {
    test('partial payment within outstanding balance is valid', () {
      expect(
        isPaymentAmountValid(amountCents: 4000, outstandingCents: 10000),
        isTrue,
      );
    });

    test('payment exactly matching outstanding balance is valid', () {
      expect(
        isPaymentAmountValid(amountCents: 10000, outstandingCents: 10000),
        isTrue,
      );
    });

    test('over payment (more than outstanding) is invalid', () {
      expect(
        isPaymentAmountValid(amountCents: 10001, outstandingCents: 10000),
        isFalse,
      );
    });

    test('zero or negative amount is invalid', () {
      expect(isPaymentAmountValid(amountCents: 0, outstandingCents: 10000), isFalse);
      expect(isPaymentAmountValid(amountCents: -500, outstandingCents: 10000), isFalse);
    });
  });

  group('isReversalAmountValid (reversal)', () {
    test('reversal within what is currently paid is valid', () {
      expect(isReversalAmountValid(amountCents: 3000, paidCents: 5000), isTrue);
    });

    test('reversal exactly equal to paid amount is valid', () {
      expect(isReversalAmountValid(amountCents: 5000, paidCents: 5000), isTrue);
    });

    test('reversal exceeding what was paid is invalid', () {
      expect(isReversalAmountValid(amountCents: 5001, paidCents: 5000), isFalse);
    });

    test('zero or negative reversal is invalid', () {
      expect(isReversalAmountValid(amountCents: 0, paidCents: 5000), isFalse);
    });
  });

  group('isApprovalVisibleForLevel', () {
    test('admin/owner sees OWNER-level approvals', () {
      expect(
        isApprovalVisibleForLevel(
          approval: {'requiredLevel': 'OWNER'},
          isAdminOrOwner: true,
        ),
        isTrue,
      );
    });

    test('non-admin does not see OWNER-level approvals (hidden for level)', () {
      expect(
        isApprovalVisibleForLevel(
          approval: {'requiredLevel': 'OWNER'},
          isAdminOrOwner: false,
        ),
        isFalse,
      );
    });

    test('non-admin sees MANAGER-level approvals', () {
      expect(
        isApprovalVisibleForLevel(
          approval: {'requiredLevel': 'MANAGER'},
          isAdminOrOwner: false,
        ),
        isTrue,
      );
    });
  });

  group('isMultiQuotationThresholdMet', () {
    test('under threshold: always met regardless of count', () {
      expect(
        isMultiQuotationThresholdMet(
          totalCents: 1000,
          thresholdCents: 5000000,
          activeCount: 1,
          minCount: 2,
        ),
        isTrue,
      );
    });

    test('over threshold with too few active quotations: not met', () {
      expect(
        isMultiQuotationThresholdMet(
          totalCents: 6000000,
          thresholdCents: 5000000,
          activeCount: 1,
          minCount: 2,
        ),
        isFalse,
      );
    });

    test('over threshold with enough active quotations: met', () {
      expect(
        isMultiQuotationThresholdMet(
          totalCents: 6000000,
          thresholdCents: 5000000,
          activeCount: 2,
          minCount: 2,
        ),
        isTrue,
      );
    });
  });

  group('isInvoicePaymentBlocked', () {
    test('total over approved amount: blocked', () {
      expect(
        isInvoicePaymentBlocked(totalCents: 10000, approvedAmountCents: 9000),
        isTrue,
      );
    });

    test('total within approved amount: not blocked', () {
      expect(
        isInvoicePaymentBlocked(totalCents: 9000, approvedAmountCents: 10000),
        isFalse,
      );
    });

    test('additional-cost approval raising approvedAmountCents unblocks it', () {
      const totalCents = 10000;
      expect(
        isInvoicePaymentBlocked(totalCents: totalCents, approvedAmountCents: 9000),
        isTrue,
      );
      // Simulates the additional-cost approval incrementing the job's
      // approvedAmountCents from 9000 to 10000+.
      expect(
        isInvoicePaymentBlocked(totalCents: totalCents, approvedAmountCents: 10000),
        isFalse,
      );
    });
  });

  group('canCloseRepairJob', () {
    test('verified + fully paid => can close', () {
      expect(
        canCloseRepairJob(
          invoiceVerificationStatus: InvoiceVerificationStatus.verified,
          paymentStatus: 'PAID',
        ),
        isTrue,
      );
    });

    test('verified but only partially paid => cannot close', () {
      expect(
        canCloseRepairJob(
          invoiceVerificationStatus: InvoiceVerificationStatus.verified,
          paymentStatus: 'PARTIAL',
        ),
        isFalse,
      );
    });

    test('not yet verified, even if paid => cannot close', () {
      expect(
        canCloseRepairJob(
          invoiceVerificationStatus: InvoiceVerificationStatus.pending,
          paymentStatus: 'PAID',
        ),
        isFalse,
      );
    });
  });

  group('nextStepFor', () {
    test('OPEN job needs diagnosis', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.open},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'SAVE MECHANICAL DIAGNOSIS');
      expect(step.actionable, isTrue);
    });

    test('DIAGNOSED job with no quotations needs one added', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.diagnosed},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'ADD A QUOTATION');
    });

    test('QUOTING with an unselected SUBMITTED quotation needs selecting', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.quoting, 'selectedQuotationId': null},
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.submitted},
        ],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'SELECT A QUOTATION');
    });

    test('return-for-correction loop: RETURNED selected quotation needs revising', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.quoting, 'selectedQuotationId': 'q1'},
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.returned},
        ],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'REVISE THE QUOTATION');
      expect(step.actionable, isTrue);
    });

    test('approval-reject loop: REJECTED selected quotation needs revising (dead-end fix)', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.quoting, 'selectedQuotationId': 'q1'},
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.rejected},
        ],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'REVISE THE QUOTATION');
      expect(step.actionable, isTrue);
    });

    test('selected SUBMITTED quotation (multi-user, different verifier) needs verifying', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.quoting,
          'selectedQuotationId': 'q1',
          'mechanicalSupervisorId': 'uidDiag',
        },
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.submitted, 'enteredBy': 'uidEnter'},
        ],
        isAdminOrOwner: true,
        userPerms: {kPermVerifyQuotation},
        currentUid: 'uidVerifier',
      );
      expect(step.title, 'VERIFY THE SELECTED QUOTATION');
      expect(step.actionable, isTrue);
    });

    test('same person as enterer cannot verify (multi-user, Test Mode OFF) — disabled with reason', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.quoting,
          'selectedQuotationId': 'q1',
          'mechanicalSupervisorId': 'uidDiag',
        },
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.submitted, 'enteredBy': 'uidEnter'},
        ],
        isAdminOrOwner: true,
        userPerms: {kPermVerifyQuotation},
        currentUid: 'uidEnter',
        testMode: false,
      );
      expect(step.actionable, isFalse);
      expect(step.disabledReason, isNotNull);
    });

    test('single-user Test Mode ON: same person as enterer CAN verify', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.quoting,
          'selectedQuotationId': 'q1',
          'mechanicalSupervisorId': 'uidEnter',
        },
        quotations: [
          {'_id': 'q1', 'status': QuotationStatus.submitted, 'enteredBy': 'uidEnter'},
        ],
        isAdminOrOwner: true,
        userPerms: {kPermVerifyQuotation},
        currentUid: 'uidEnter',
        testMode: true,
      );
      expect(step.actionable, isTrue);
    });

    test('VERIFIED job needs REQUEST APPROVAL', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.verified},
        quotations: const [],
        isAdminOrOwner: false,
        userPerms: {kPermRequestApproval},
        currentUid: 'u1',
      );
      expect(step.title, 'REQUEST APPROVAL');
      expect(step.actionable, isTrue);
    });

    test('PENDING_APPROVAL is a waiting state, not actionable by the requester', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.pendingApproval},
        quotations: const [],
        isAdminOrOwner: false,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'WAITING FOR APPROVAL');
      expect(step.actionable, isFalse);
    });

    test('APPROVED job needs START REPAIR', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.approved},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'START REPAIR');
    });

    test('additional cost pending blocks MARK WORK COMPLETED next step', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.inRepair, 'additionalCostPending': true},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'WAITING FOR ADDITIONAL COST APPROVAL');
      expect(step.actionable, isFalse);
    });

    test('IN_REPAIR with no pending additional cost needs MARK WORK COMPLETED', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.inRepair, 'additionalCostPending': false},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'MARK WORK COMPLETED');
    });

    test('final inspection FAIL rework loop: IN_REPAIR with reworkCount>0 still actionable', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.inRepair,
          'additionalCostPending': false,
          'reworkCount': 2,
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'MARK WORK COMPLETED');
      expect(step.actionable, isTrue);
    });

    test('FINAL_INSPECTION: same person as work-completer blocked (multi-user)', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.finalInspection,
          'workCompletedBy': 'uidCompleter',
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'uidCompleter',
        testMode: false,
      );
      expect(step.actionable, isFalse);
    });

    test('FINAL_INSPECTION: Test Mode ON allows the same person to inspect', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.finalInspection,
          'workCompletedBy': 'uidCompleter',
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'uidCompleter',
        testMode: true,
      );
      expect(step.actionable, isTrue);
    });

    test('COMPLETED with no invoice needs ADD INVOICE', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.completed, 'invoiceId': null},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'ADD INVOICE');
    });

    test('COMPLETED with invoice not yet PAID needs VERIFY/PAY', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.completed,
          'invoiceId': 'inv1',
          'paymentStatus': 'PARTIAL',
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'VERIFY / PAY THE INVOICE');
    });

    test('COMPLETED with invoice fully PAID needs CLOSE JOB', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.completed,
          'invoiceId': 'inv1',
          'paymentStatus': 'PAID',
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'CLOSE JOB');
      expect(step.actionable, isTrue);
    });

    test('CLOSED job has no further action', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.closed},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'JOB CLOSED');
      expect(step.actionable, isFalse);
    });
  });

  group('nextStepFor — simple mode (Daily Vehicle Inspection flow)', () {
    test('OPEN simple-mode job needs the mechanic form submitted', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.open, 'simpleMode': true},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'SUBMIT FOR APPROVAL');
    });

    test('DIAGNOSED simple-mode job (returned by supervisor) needs resubmitting', () {
      final step = nextStepFor(
        job: {
          'repairStatus': RepairStatus.diagnosed,
          'simpleMode': true,
          'returnReason': 'Wrong garage quoted',
        },
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: {kPermDiagnose},
        currentUid: 'u1',
      );
      expect(step.title, 'SUBMIT FOR APPROVAL');
      expect(step.actionable, isTrue);
    });

    test('DIAGNOSED non-simple-mode job still falls through to the quotation flow', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.diagnosed},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'ADD A QUOTATION');
    });

    test('APPROVED simple-mode job needs MARK DONE, not START REPAIR', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.approved, 'simpleMode': true},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: {kPermRepairWork},
        currentUid: 'u1',
      );
      expect(step.title, 'MARK DONE');
      expect(step.actionable, isTrue);
    });

    test('APPROVED non-simple-mode job still needs START REPAIR', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.approved},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: {kPermRepairWork},
        currentUid: 'u1',
      );
      expect(step.title, 'START REPAIR');
    });

    test('COMPLETED simple-mode job is terminal, not asking for an invoice', () {
      final step = nextStepFor(
        job: {'repairStatus': RepairStatus.completed, 'simpleMode': true},
        quotations: const [],
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'u1',
      );
      expect(step.title, 'REPAIR COMPLETE');
      expect(step.actionable, isFalse);
    });
  });

  group('previousRepairsForCategory', () {
    test('same-category records sort before other-category records', () {
      final records = [
        {'category': 'ENGINE', 'atMillis': 300},
        {'category': 'BRAKES', 'atMillis': 500},
        {'category': 'ENGINE', 'atMillis': 100},
      ];
      final sorted = previousRepairsForCategory(records: records, category: 'ENGINE');
      expect(sorted.map((r) => r['category']), ['ENGINE', 'ENGINE', 'BRAKES']);
    });

    test('within the same category, most recent (highest atMillis) comes first', () {
      final records = [
        {'category': 'ENGINE', 'atMillis': 100},
        {'category': 'ENGINE', 'atMillis': 300},
        {'category': 'ENGINE', 'atMillis': 200},
      ];
      final sorted = previousRepairsForCategory(records: records, category: 'ENGINE');
      expect(sorted.map((r) => r['atMillis']), [300, 200, 100]);
    });

    test('non-matching records still sort by recency among themselves', () {
      final records = [
        {'category': 'BRAKES', 'atMillis': 100},
        {'category': 'TYRES', 'atMillis': 300},
        {'category': 'BODY', 'atMillis': 200},
      ];
      final sorted = previousRepairsForCategory(records: records, category: 'ENGINE');
      expect(sorted.map((r) => r['category']), ['TYRES', 'BODY', 'BRAKES']);
    });

    test('empty input returns empty output', () {
      expect(previousRepairsForCategory(records: const [], category: 'ENGINE'), isEmpty);
    });

    test('does not mutate the input list', () {
      final records = [
        {'category': 'BRAKES', 'atMillis': 100},
        {'category': 'ENGINE', 'atMillis': 50},
      ];
      final original = List<Map<String, dynamic>>.from(records);
      previousRepairsForCategory(records: records, category: 'ENGINE');
      expect(records, original);
    });
  });

  group('computeServiceItemDue', () {
    test('never serviced: no lastDoneKm -> NEVER_SERVICED, no kmRemaining claimed', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Engine Oil',
        intervalKm: 5000,
        warnBeforeKm: 1000,
        lastDoneKm: null,
        lastDoneDate: null,
        currentKm: 12000,
        now: DateTime(2026, 1, 1),
      );
      expect(due.status, ServiceItemDueStatus.neverServiced);
      expect(due.kmRemaining, isNull);
    });

    test('OK: plenty of km remaining', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Engine Oil',
        intervalKm: 5000,
        warnBeforeKm: 1000,
        lastDoneKm: 10000,
        lastDoneDate: DateTime(2026, 1, 1),
        currentKm: 11000,
        now: DateTime(2026, 2, 1),
      );
      expect(due.status, ServiceItemDueStatus.ok);
      expect(due.kmRemaining, 4000);
    });

    test('DUE_SOON: within warnBeforeKm of the interval', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Engine Oil',
        intervalKm: 5000,
        warnBeforeKm: 1000,
        lastDoneKm: 10000,
        lastDoneDate: DateTime(2026, 1, 1),
        currentKm: 14500,
        now: DateTime(2026, 2, 1),
      );
      expect(due.status, ServiceItemDueStatus.dueSoon);
      expect(due.kmRemaining, 500);
    });

    test('OVERDUE by km: current km at or past lastDoneKm + intervalKm', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Engine Oil',
        intervalKm: 5000,
        warnBeforeKm: 1000,
        lastDoneKm: 10000,
        lastDoneDate: DateTime(2026, 1, 1),
        currentKm: 15200,
        now: DateTime(2026, 2, 1),
      );
      expect(due.status, ServiceItemDueStatus.overdue);
      expect(due.kmRemaining, -200);
    });

    test('OVERDUE by days even when km is not yet due', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Battery Check',
        intervalKm: 50000,
        intervalDays: 180,
        warnBeforeKm: 1000,
        lastDoneKm: 10000,
        lastDoneDate: DateTime(2026, 1, 1),
        currentKm: 10500,
        now: DateTime(2026, 7, 10),
      );
      expect(due.status, ServiceItemDueStatus.overdue);
    });

    test('currentKm unknown (no GPS, no fresh reading): kmRemaining is null, not OVERDUE', () {
      final due = computeServiceItemDue(
        itemId: 'i1',
        itemName: 'Engine Oil',
        intervalKm: 5000,
        warnBeforeKm: 1000,
        lastDoneKm: 10000,
        lastDoneDate: DateTime(2026, 1, 1),
        currentKm: null,
        now: DateTime(2026, 2, 1),
      );
      expect(due.status, ServiceItemDueStatus.ok);
      expect(due.kmRemaining, isNull);
    });
  });

  group('latestApprovedDoneForItem', () {
    test('picks the most recent APPROVED record that ticked the item', () {
      final records = [
        {
          'status': ServiceRecordStatus.approved,
          'itemIds': ['i1'],
          'currentKm': 10000,
          'serviceDateMillis': 1000,
        },
        {
          'status': ServiceRecordStatus.approved,
          'itemIds': ['i1'],
          'currentKm': 15000,
          'serviceDateMillis': 2000,
        },
      ];
      final result = latestApprovedDoneForItem(records: records, itemId: 'i1');
      expect(result.lastDoneKm, 15000);
      expect(result.lastDoneDate, DateTime.fromMillisecondsSinceEpoch(2000));
    });

    test('ignores SUBMITTED and RETURNED records', () {
      final records = [
        {
          'status': ServiceRecordStatus.submitted,
          'itemIds': ['i1'],
          'currentKm': 99999,
          'serviceDateMillis': 9999999,
        },
        {
          'status': ServiceRecordStatus.returned,
          'itemIds': ['i1'],
          'currentKm': 88888,
          'serviceDateMillis': 8888888,
        },
        {
          'status': ServiceRecordStatus.approved,
          'itemIds': ['i1'],
          'currentKm': 10000,
          'serviceDateMillis': 1000,
        },
      ];
      final result = latestApprovedDoneForItem(records: records, itemId: 'i1');
      expect(result.lastDoneKm, 10000);
    });

    test('ignores approved records that did not tick this item', () {
      final records = [
        {
          'status': ServiceRecordStatus.approved,
          'itemIds': ['otherItem'],
          'currentKm': 10000,
          'serviceDateMillis': 1000,
        },
      ];
      final result = latestApprovedDoneForItem(records: records, itemId: 'i1');
      expect(result.lastDoneKm, isNull);
      expect(result.lastDoneDate, isNull);
    });

    test('no matching records at all -> null', () {
      final result = latestApprovedDoneForItem(records: const [], itemId: 'i1');
      expect(result.lastDoneKm, isNull);
    });

    test('extra items (free text, no itemId) never match a schedule item', () {
      final records = [
        {
          'status': ServiceRecordStatus.approved,
          'itemIds': <String>[], // only extraItems were logged, no scheduled items ticked
          'currentKm': 10000,
          'serviceDateMillis': 1000,
        },
      ];
      final result = latestApprovedDoneForItem(records: records, itemId: 'i1');
      expect(result.lastDoneKm, isNull);
    });
  });

  group('serviceNextStepFor', () {
    test('SUBMITTED: waiting for approval, actionable for a different approver', () {
      final step = serviceNextStepFor(
        record: {'status': ServiceRecordStatus.submitted, 'submittedBy': 'uidMechanic'},
        isAdminOrOwner: false,
        userPerms: {kPermServiceApprove},
        currentUid: 'uidManager',
      );
      expect(step.title, 'WAITING FOR APPROVAL');
      expect(step.actionable, isTrue);
    });

    test('SUBMITTED: same user as submitter cannot approve (Test Mode OFF)', () {
      final step = serviceNextStepFor(
        record: {'status': ServiceRecordStatus.submitted, 'submittedBy': 'uidMechanic'},
        isAdminOrOwner: false,
        userPerms: {kPermServiceApprove},
        currentUid: 'uidMechanic',
        testMode: false,
      );
      expect(step.actionable, isFalse);
    });

    test('SUBMITTED: Test Mode ON allows the same user to approve', () {
      final step = serviceNextStepFor(
        record: {'status': ServiceRecordStatus.submitted, 'submittedBy': 'uidMechanic'},
        isAdminOrOwner: false,
        userPerms: {kPermServiceApprove},
        currentUid: 'uidMechanic',
        testMode: true,
      );
      expect(step.actionable, isTrue);
    });

    test('RETURNED: needs edit and resubmit, gated on SERVICE_DO', () {
      final step = serviceNextStepFor(
        record: {'status': ServiceRecordStatus.returned, 'submittedBy': 'uidMechanic'},
        isAdminOrOwner: false,
        userPerms: {kPermServiceDo},
        currentUid: 'uidMechanic',
      );
      expect(step.title, 'EDIT AND RESUBMIT');
      expect(step.actionable, isTrue);
    });

    test('APPROVED: terminal, not actionable', () {
      final step = serviceNextStepFor(
        record: {'status': ServiceRecordStatus.approved, 'submittedBy': 'uidMechanic'},
        isAdminOrOwner: true,
        userPerms: const {},
        currentUid: 'uidManager',
      );
      expect(step.title, 'APPROVED');
      expect(step.actionable, isFalse);
    });
  });

  group('computeNextMilestone', () {
    test('before the first milestone (45,000): OK', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: 40000,
        now: DateTime(2026, 1, 1),
      );
      expect(m.number, 1);
      expect(m.milestoneKm, 45000);
      expect(m.status, ServiceMilestoneStatus.ok);
    });

    test('within warnBeforeKm of 45,000: DUE_SOON', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: 44600,
        now: DateTime(2026, 1, 1),
      );
      expect(m.status, ServiceMilestoneStatus.dueSoon);
    });

    test('just past 45,000 (not yet a full interval past): OVERDUE', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: 45200,
        now: DateTime(2026, 1, 1),
      );
      expect(m.number, 1);
      expect(m.status, ServiceMilestoneStatus.overdue);
    });

    test('a full interval past 45,000 with no approved record: MISSED', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: 95000,
        now: DateTime(2026, 1, 1),
      );
      expect(m.number, 1);
      expect(m.status, ServiceMilestoneStatus.missed);
    });

    test('milestone 1 approved -> next milestone is 90,000, not shifted by '
        'when milestone 1 actually happened', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {1},
        currentKm: 85000,
        now: DateTime(2026, 1, 1),
      );
      expect(m.number, 2);
      expect(m.milestoneKm, 90000);
      expect(m.status, ServiceMilestoneStatus.ok);
    });

    test('non-contiguous completed milestones still find the smallest gap', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {1, 3},
        currentKm: 100000,
        now: DateTime(2026, 1, 1),
      );
      expect(m.number, 2);
      expect(m.milestoneKm, 90000);
    });

    test('currentKm unknown: no status escalation from km, stays OK', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: null,
        now: DateTime(2026, 1, 1),
      );
      expect(m.status, ServiceMilestoneStatus.ok);
      expect(m.kmToMilestone, isNull);
    });

    test('intervalDays overdue even when km has not reached the milestone', () {
      final m = computeNextMilestone(
        intervalKm: 45000,
        warnBeforeKm: 1000,
        completedMilestoneNumbers: const {},
        currentKm: 10000,
        now: DateTime(2026, 7, 1),
        intervalDays: 180,
        lastApprovedDoneDate: DateTime(2026, 1, 1),
      );
      expect(m.status, ServiceMilestoneStatus.overdue);
    });
  });

  group('evaluateServiceTiming', () {
    test('within tolerance: ON TIME', () {
      final result = evaluateServiceTiming(
        milestoneKm: 45000,
        doneKm: 45300,
        toleranceKm: 500,
      );
      expect(result.onTime, isTrue);
      expect(result.lateByKm, 300);
    });

    test('exactly at tolerance: ON TIME', () {
      final result = evaluateServiceTiming(
        milestoneKm: 45000,
        doneKm: 45500,
        toleranceKm: 500,
      );
      expect(result.onTime, isTrue);
      expect(result.lateByKm, 500);
    });

    test('beyond tolerance: LATE BY n km', () {
      final result = evaluateServiceTiming(
        milestoneKm: 45000,
        doneKm: 45800,
        toleranceKm: 500,
      );
      expect(result.onTime, isFalse);
      expect(result.lateByKm, 800);
    });

    test('done early (negative lateByKm): ON TIME', () {
      final result = evaluateServiceTiming(
        milestoneKm: 45000,
        doneKm: 44700,
        toleranceKm: 500,
      );
      expect(result.onTime, isTrue);
      expect(result.lateByKm, -300);
    });
  });

  group('isChecklistSubmitValid', () {
    test('all lines done: valid', () {
      expect(
        isChecklistSubmitValid([
          {'id': '1', 'done': true},
          {'id': '2', 'done': true},
        ]),
        isTrue,
      );
    });

    test('a not-done line with a reason: valid', () {
      expect(
        isChecklistSubmitValid([
          {'id': '1', 'done': false, 'notDoneReason': 'PART NOT AVAILABLE'},
        ]),
        isTrue,
      );
    });

    test('a not-done line with no reason: invalid', () {
      expect(
        isChecklistSubmitValid([
          {'id': '1', 'done': false, 'notDoneReason': ''},
        ]),
        isFalse,
      );
    });

    test('a not-done line with a missing reason key: invalid', () {
      expect(
        isChecklistSubmitValid([
          {'id': '1', 'done': false},
        ]),
        isFalse,
      );
    });

    test('empty checklist: valid (on-demand service with no schedule)', () {
      expect(isChecklistSubmitValid(const []), isTrue);
    });
  });

  group('dailyCheckDocId / dailyCheckDateKey', () {
    test('same vehicle + same day -> same doc id (one submission per day)', () {
      final a = dailyCheckDocId('WP-1234', DateTime(2026, 10, 26, 8, 0));
      final b = dailyCheckDocId('WP-1234', DateTime(2026, 10, 26, 17, 45));
      expect(a, equals(b));
      expect(a, equals('WP-1234_2026-10-26'));
    });

    test('same vehicle + different day -> different doc id', () {
      final a = dailyCheckDocId('WP-1234', DateTime(2026, 10, 26));
      final b = dailyCheckDocId('WP-1234', DateTime(2026, 10, 27));
      expect(a, isNot(equals(b)));
    });

    test('different vehicle + same day -> different doc id', () {
      final a = dailyCheckDocId('WP-1234', DateTime(2026, 10, 26));
      final b = dailyCheckDocId('WP-5678', DateTime(2026, 10, 26));
      expect(a, isNot(equals(b)));
    });

    test('date key pads single-digit month/day', () {
      expect(dailyCheckDateKey(DateTime(2026, 1, 5)), equals('2026-01-05'));
    });
  });

  group('isDailyCheckSubmitValid', () {
    test('all 3 checks OK with photos: valid', () {
      expect(
        isDailyCheckSubmitValid([
          {'status': 'OK', 'hasPhoto': true},
          {'status': 'OK', 'hasPhoto': true},
          {'status': 'OK', 'hasPhoto': true},
        ]),
        isTrue,
      );
    });

    test('a LOW check with a photo: still valid (LOW does not block submit)', () {
      expect(
        isDailyCheckSubmitValid([
          {'status': 'LOW', 'hasPhoto': true},
          {'status': 'OK', 'hasPhoto': true},
        ]),
        isTrue,
      );
    });

    test('a check missing its required photo: invalid', () {
      expect(
        isDailyCheckSubmitValid([
          {'status': 'OK', 'hasPhoto': true},
          {'status': 'LOW', 'hasPhoto': false},
        ]),
        isFalse,
      );
    });

    test('a check with no status set: invalid', () {
      expect(
        isDailyCheckSubmitValid([
          {'status': '', 'hasPhoto': true},
        ]),
        isFalse,
      );
    });

    test('empty check list: invalid (unlike the on-demand checklist, daily check always has lines)', () {
      expect(isDailyCheckSubmitValid(const []), isFalse);
    });
  });

  group('dailyCheckAnyLow', () {
    test('no LOW checks: false', () {
      expect(
        dailyCheckAnyLow([
          {'status': 'OK'},
          {'status': 'OK'},
        ]),
        isFalse,
      );
    });

    test('one LOW check: true', () {
      expect(
        dailyCheckAnyLow([
          {'status': 'OK'},
          {'status': 'LOW'},
        ]),
        isTrue,
      );
    });
  });

  group('normalizeVehicleNumber', () {
    test('trims and uppercases', () {
      expect(normalizeVehicleNumber(' wp-1234 '), equals('WP-1234'));
    });

    test('already-normalized input is unchanged', () {
      expect(normalizeVehicleNumber('WP-1234'), equals('WP-1234'));
    });

    test('dailyCheckDocId normalizes before building the id, so differently '
        'cased/spaced input for the same vehicle collides on one doc', () {
      final a = dailyCheckDocId('wp-1234', DateTime(2026, 10, 26));
      final b = dailyCheckDocId(' WP-1234 ', DateTime(2026, 10, 26));
      expect(a, equals(b));
      expect(a, equals('WP-1234_2026-10-26'));
    });
  });

  group('dailyCheckAllowSkip', () {
    test('requireDailyCheck true, not admin/owner: no skip', () {
      expect(
        dailyCheckAllowSkip(requireDailyCheck: true, isAdminOrOwner: false),
        isFalse,
      );
    });

    test('requireDailyCheck false, not admin/owner: skip allowed', () {
      expect(
        dailyCheckAllowSkip(requireDailyCheck: false, isAdminOrOwner: false),
        isTrue,
      );
    });

    test('requireDailyCheck true, admin/owner: skip allowed (override)', () {
      expect(
        dailyCheckAllowSkip(requireDailyCheck: true, isAdminOrOwner: true),
        isTrue,
      );
    });

    test('requireDailyCheck false, admin/owner: skip allowed', () {
      expect(
        dailyCheckAllowSkip(requireDailyCheck: false, isAdminOrOwner: true),
        isTrue,
      );
    });
  });
}
