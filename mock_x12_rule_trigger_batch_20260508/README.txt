Mock X12 Rule Trigger Batch (2026-05-08)

Purpose:
- These 10 files are designed to trigger targeted business rules for regression testing.
- Some overlaps are expected because several active rules share thresholds/conditions.

Files and intended trigger focus:
1) 01_weekend_office_visit.x12 -> WeekendOfficeVisit
2) 02_impossible_dates_1899.x12 -> ImpossibleDates
3) 03_future_service_date_2099.x12 -> FutureServiceDate
4) 04_missing_required_fields_no_dob.x12 -> MissingRequiredFields
5) 05_missing_diagnosis_codes.x12 -> MissingDiagnosisCodes
6) 06_excessive_total_charges_800k.x12 -> ExcessiveTotalCharges (and likely other high-value rules)
7) 07_suspiciously_low_charge_3.x12 -> SuspiciouslyLowCharge
8) 08_unauthorized_procedure_6000.x12 -> UnauthorizedProcedure
9) 09_high_complexity_er_visit_12000.x12 -> HighComplexityERVisit
10) 10_missing_provider_taxonomy_1500.x12 -> MissingProviderTaxonomy

Notes:
- NPI-dependent rule triggering may be preempted by NPPES pre-validation in app flow.
- This set is for controlled negative/edge testing and not for production-like clean claims.
