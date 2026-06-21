# Actual Rule Match Report

Generated: 2026-05-08 21:00:00.232685Z

| File | Intended Trigger | NPPES | Actual Risk | Actual Matched Rules | Notes |
|---|---|---|---|---|---|
| 01_weekend_office_visit.x12 | WeekendOfficeVisit | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 02_impossible_dates_1899.x12 | ImpossibleDates | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 03_future_service_date_2099.x12 | FutureServiceDate | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 04_missing_required_fields_no_dob.x12 | MissingRequiredFields | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 05_missing_diagnosis_codes.x12 | MissingDiagnosisCodes | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 06_excessive_total_charges_800k.x12 | ExcessiveTotalCharges | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 07_suspiciously_low_charge_3.x12 | SuspiciouslyLowCharge | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 08_unauthorized_procedure_6000.x12 | UnauthorizedProcedure | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 09_high_complexity_er_visit_12000.x12 | HighComplexityERVisit | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
| 10_missing_provider_taxonomy_1500.x12 | MissingProviderTaxonomy | pass | CriticalRisk | missing_diagnosis_codes, missing_required_fields |  |
