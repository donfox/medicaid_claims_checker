alias MedicaidClaimsChecker.Repo
alias MedicaidClaimsChecker.Claims.BusinessRule
alias MedicaidClaimsChecker.Claims.RuleCatalogue
alias MedicaidClaimsChecker.Claims.NppesProvider
alias MedicaidClaimsChecker.Nppes.RefreshConfig

now = DateTime.utc_now() |> DateTime.truncate(:second)

# --- Mock NPPES Providers (for testing) ---

mock_providers = [
  # --- Providers matching test fixture NPIs (with taxonomy) ---
  # claim_normal_approved.json, claim_routine_office_visit.json
  %{
    npi: "1234567890",
    entity_type: 2,
    provider_name: "Riverside Family Practice",
    credential: nil,
    taxonomy: "207Q00000X",
    state: "IL",
    enumeration_date: ~D[2021-02-19],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-10],
    inserted_at: now,
    updated_at: now
  },
  # claim_normal_approved.json
  %{
    npi: "1234567901",
    entity_type: 2,
    provider_name: "Kansas City Medical Center",
    credential: nil,
    taxonomy: "207Q00000X",
    state: "MO",
    enumeration_date: ~D[2015-12-01],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-02-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_low_value_trigger.json
  %{
    npi: "1234567891",
    entity_type: 2,
    provider_name: "Budget Clinic",
    credential: nil,
    taxonomy: "208D00000X",
    state: "TX",
    enumeration_date: ~D[2024-06-15],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-06-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_invalid_state_trigger.json
  %{
    npi: "1234567892",
    entity_type: 1,
    provider_name: "Unknown Provider LLC",
    credential: nil,
    taxonomy: nil,
    state: "XX",
    enumeration_date: ~D[2025-01-20],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2025-01-20],
    inserted_at: now,
    updated_at: now
  },
  # claim_high_risk_combo_trigger.json
  %{
    npi: "1234567893",
    entity_type: 2,
    provider_name: "New Startup Clinic",
    credential: nil,
    taxonomy: "261QD0000X",
    state: "FL",
    enumeration_date: ~D[2025-12-01],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2025-12-01],
    inserted_at: now,
    updated_at: now
  },
  # claim_urgent_review_99285.json
  %{
    npi: "1234567894",
    entity_type: 2,
    provider_name: "Emergency Medical Center",
    credential: nil,
    taxonomy: "207P00000X",
    state: "IL",
    enumeration_date: ~D[2018-03-10],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_missing_auth_trigger.json
  %{
    npi: "1234567895",
    entity_type: 2,
    provider_name: "Suspicious Medical Group",
    credential: nil,
    taxonomy: "193200000X",
    state: "NV",
    enumeration_date: ~D[2025-09-15],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2025-09-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_multi_action_trigger.json
  %{
    npi: "1234567896",
    entity_type: 2,
    provider_name: "Extreme Services Inc",
    credential: nil,
    taxonomy: "283X00000X",
    state: "CA",
    enumeration_date: ~D[2025-11-15],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2025-11-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_complex_fraud_trigger.json
  %{
    npi: "1234567897",
    entity_type: 2,
    provider_name: "High-Risk Medical Services",
    credential: nil,
    taxonomy: "207X00000X",
    state: "AZ",
    enumeration_date: ~D[2024-02-28],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-02-28],
    inserted_at: now,
    updated_at: now
  },
  # claim_specialist_consultation.json
  %{
    npi: "1987654321",
    entity_type: 2,
    provider_name: "Capitol Orthopedic Specialists",
    credential: nil,
    taxonomy: "207X00000X",
    state: "TX",
    enumeration_date: ~D[2020-02-20],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-03-01],
    inserted_at: now,
    updated_at: now
  },
  # claim_preventive_care.json
  %{
    npi: "1122334455",
    entity_type: 2,
    provider_name: "Northside Primary Care",
    credential: nil,
    taxonomy: "207R00000X",
    state: "CO",
    enumeration_date: ~D[2016-02-22],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-20],
    inserted_at: now,
    updated_at: now
  },
  # claim_outpatient_lab.json
  %{
    npi: "1555666777",
    entity_type: 2,
    provider_name: "Midwest Diagnostics Laboratory",
    credential: nil,
    taxonomy: "207ZP0102X",
    state: "OH",
    enumeration_date: ~D[2014-02-24],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-02-01],
    inserted_at: now,
    updated_at: now
  },
  # claim_extreme_amount.json
  %{
    npi: "1098765432",
    entity_type: 2,
    provider_name: "Metro Regional Hospital",
    credential: nil,
    taxonomy: "208G00000X",
    state: "NY",
    enumeration_date: ~D[2012-06-01],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-05],
    inserted_at: now,
    updated_at: now
  },
  # claim_future_service_date.json
  %{
    npi: "1234509876",
    entity_type: 2,
    provider_name: "Eastside Medical Group",
    credential: nil,
    taxonomy: "208D00000X",
    state: "AZ",
    enumeration_date: ~D[2024-06-15],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-06-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_missing_diagnosis.json
  %{
    npi: "1357924680",
    entity_type: 2,
    provider_name: "Westfield Urgent Care",
    credential: nil,
    taxonomy: "261QU0200X",
    state: "GA",
    enumeration_date: ~D[2024-02-25],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-02-25],
    inserted_at: now,
    updated_at: now
  },
  # claim_no_authorization.json
  %{
    npi: "1473698520",
    entity_type: 2,
    provider_name: "Bayside Surgical Center",
    credential: nil,
    taxonomy: "261QA0600X",
    state: "WA",
    enumeration_date: ~D[2023-01-15],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-10],
    inserted_at: now,
    updated_at: now
  },
  # claim_suspicious_low_amount.json
  %{
    npi: "1928374650",
    entity_type: 2,
    provider_name: "Greenway Behavioral Health",
    credential: nil,
    taxonomy: "2084P0800X",
    state: "OR",
    enumeration_date: ~D[2023-08-10],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-15],
    inserted_at: now,
    updated_at: now
  },
  # claim_high_value_threshold.json
  %{
    npi: "1654321987",
    entity_type: 2,
    provider_name: "University Orthopedic Hospital",
    credential: nil,
    taxonomy: "207X00000X",
    state: "PA",
    enumeration_date: ~D[2017-02-26],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-02-10],
    inserted_at: now,
    updated_at: now
  },
  # claim_new_provider_high_value.json
  %{
    npi: "1829384756",
    entity_type: 2,
    provider_name: "Sunrise Pain Management Center",
    credential: nil,
    taxonomy: "208VP0014X",
    state: "TN",
    enumeration_date: ~D[2026-01-27],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2026-01-27],
    inserted_at: now,
    updated_at: now
  },
  # claim_er_high_complexity.json
  %{
    npi: "1736251948",
    entity_type: 2,
    provider_name: "St. Catherine Emergency Center",
    credential: nil,
    taxonomy: "207P00000X",
    state: "TX",
    enumeration_date: ~D[2019-02-25],
    deactivation_date: nil,
    reactivation_date: nil,
    last_update_date: ~D[2024-01-20],
    inserted_at: now,
    updated_at: now
  },
  # claim_invalid_npi.json (7-digit NPI — will NOT be inserted due to length validation)
  # NPI "1234567" is intentionally invalid; no NPPES record for it.

  # --- Additional mock providers for NPPES validation testing ---
  %{
    npi: "1111111112",
    entity_type: 1,
    provider_name: "Dr. Maria Garcia",
    credential: "MD",
    taxonomy: "207Q00000X",
    state: "FL",
    enumeration_date: ~D[2015-09-01],
    deactivation_date: ~D[2023-06-15],
    reactivation_date: nil,
    last_update_date: ~D[2023-06-15],
    inserted_at: now,
    updated_at: now
  },
  %{
    npi: "2222222223",
    entity_type: 1,
    provider_name: "Dr. James Wilson",
    credential: "MD",
    taxonomy: "207R00000X",
    state: "IL",
    enumeration_date: ~D[2008-11-20],
    deactivation_date: ~D[2022-03-01],
    reactivation_date: ~D[2022-09-15],
    last_update_date: ~D[2022-09-15],
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  NppesProvider,
  mock_providers,
  on_conflict: {:replace, [:provider_name, :credential, :taxonomy, :state, :deactivation_date, :reactivation_date, :last_update_date, :updated_at]},
  conflict_target: [:npi]
)

# --- Business Rules (DSL text) ---

rules = [
  %{
    name: "HighValueReview",
    rule_text:
      """
      RULE high_value_review
      DESCRIPTION \"Flag high-value claims for manual review\"
      WHEN 2300.CLM.claim_amount > 50000
      THEN REQUIRE_REVIEW \"Exceeds high-value threshold\"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "WeekendOfficeVisit",
    rule_text:
      """
      RULE weekend_office_visit
      DESCRIPTION \"Office visit on weekend with elevated amount\"
      WHEN 2400.SV1.place_of_service = \"11\"
           AND 2400.DTP.service_day_of_week = \"SAT\"
           AND 2300.CLM.claim_amount > 500
      THEN REQUIRE_REVIEW \"Weekend office visit requires verification\"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InpatientMismatch",
    rule_text:
      """
      RULE inpatient_mismatch
      DESCRIPTION \"Outpatient place of service with inpatient billing\"
      WHEN 2400.SV1.place_of_service = \"22\"
           AND 2300.CLM.facility_type = \"Inpatient\"
           AND 2300.CLM.claim_amount > 10000
      THEN REJECT \"Inpatient/outpatient mismatch detected\"
      END
      """
      |> String.trim(),
    active: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  BusinessRule,
  rules,
  on_conflict: {:replace, [:rule_text, :active, :updated_at]},
  conflict_target: [:name]
)

# --- Rule Catalogue: Default Rules (always-on, protected) ---

default_catalogue_entries = [
  %{
    name: "ImpossibleDates",
    description: "Rejects claims with service dates in the future or before 1900",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "ExtremeAmounts",
    description: "Flags claims with total charges exceeding $1,000,000",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "DuplicateClaims",
    description: "Detects duplicate claim submissions within 30 days for the same member and provider",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "MissingRequiredFields",
    description: "Ensures all mandatory X12 837 fields are present in the claim payload",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InvalidProviderNPI",
    description: "Validates that the billing provider NPI is a 10-digit Luhn-valid number",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "NPPESProviderLookup",
    description: "Validates provider NPI exists in the NPPES national registry and was active on the date of service",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  default_catalogue_entries,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# --- Rule Catalogue: BA Rules (matching existing business rules) ---

ba_catalogue_entries = [
  %{
    name: "HighValueReview",
    description: "Flag high-value claims over $50,000 for manual review",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "WeekendOfficeVisit",
    description: "Office visit on weekend with elevated amount requires verification",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InpatientMismatch",
    description: "Outpatient place of service with inpatient billing code — currently inactive",
    entry_type: "BA Rule",
    status: "Inactive",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  ba_catalogue_entries,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# ---------------------------------------------------------------------------
# FRESH RULE SET — added alongside existing entries
# ---------------------------------------------------------------------------

# --- New Default Rules (hardcoded logic in Haskell; catalogue metadata only) ---

new_default_rules = [
  %{
    name: "FutureServiceDate",
    description: "Rejects claims where the date of service has not yet occurred",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InvalidNPIFormat",
    description: "Rejects claims where the billing provider NPI is not exactly 10 digits",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "MissingDiagnosisCodes",
    description: "Rejects claims that contain no diagnosis codes",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "ExcessiveTotalCharges",
    description: "Flags claims with total charges exceeding $750,000 as potential fraud",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "PatientAgeOutOfRange",
    description: "Rejects claims where the patient age is negative or exceeds 130 years",
    entry_type: "Default Rule",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  new_default_rules,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# --- Default Rules: DSL text stored in business_rules table ---
# These correspond to the Default Rule catalogue entries and will be
# evaluated alongside BA Rules via active_catalog_rules_text().

default_business_rules = [
  %{
    name: "ImpossibleDates",
    rule_text:
      """
      RULE impossible_dates
      "Rejects claims with service dates in the future or before 1900"
      WHEN is_future_date(service_lines.0.date_of_service)
        OR is_date_before(service_lines.0.date_of_service, "1900-01-01")
      THEN REJECT "Impossible service date detected";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "ExtremeAmounts",
    rule_text:
      """
      RULE extreme_amounts
      "Flags claims with total charges exceeding $1,000,000"
      WHEN claim_totals.total_charges > 1000000
      THEN FLAG_FRAUD "Extreme billing amount exceeds $1M";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "MissingRequiredFields",
    rule_text:
      """
      RULE missing_required_fields
      "Ensures all mandatory fields are present in the claim payload"
      WHEN claim_id IS NULL
        OR provider.npi IS NULL
        OR patient.date_of_birth IS NULL
        OR financial.claim_amount IS NULL
      THEN REJECT "Missing required claim field";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InvalidProviderNPI",
    rule_text:
      """
      RULE invalid_provider_npi
      "Validates that the billing provider NPI passes Luhn-10 checksum"
      WHEN provider.npi IS NOT NULL
        AND NOT is_valid_npi(provider.npi)
      THEN REJECT "Provider NPI fails Luhn-10 validation";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "FutureServiceDate",
    rule_text:
      """
      RULE future_service_date
      "Rejects claims where the date of service has not yet occurred"
      WHEN is_future_date(service_lines.0.date_of_service)
      THEN REJECT "Service date is in the future";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "InvalidNPIFormat",
    rule_text:
      """
      RULE invalid_npi_format
      "Rejects claims where the billing provider NPI is not exactly 10 digits"
      WHEN provider.npi IS NOT NULL
        AND NOT is_npi_format(provider.npi)
      THEN REJECT "Provider NPI is not a valid 10-digit number";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "MissingDiagnosisCodes",
    rule_text:
      """
      RULE missing_diagnosis_codes
      "Rejects claims that contain no diagnosis codes"
      WHEN COUNT(diagnosis_codes) = 0
      THEN REJECT "No diagnosis codes present on claim";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "ExcessiveTotalCharges",
    rule_text:
      """
      RULE excessive_total_charges
      "Flags claims with total charges exceeding $750,000 as potential fraud"
      WHEN claim_totals.total_charges > 750000
      THEN FLAG_FRAUD "Total charges exceed $750K threshold";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "PatientAgeOutOfRange",
    rule_text:
      """
      RULE patient_age_out_of_range
      "Rejects claims where the patient age is negative or exceeds 130 years"
      WHEN patient.date_of_birth IS NOT NULL
        AND NOT is_age_valid(patient.date_of_birth, 0, 130)
      THEN REJECT "Patient age is out of valid range (0-130)";
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  BusinessRule,
  default_business_rules,
  on_conflict: {:replace, [:rule_text, :active, :updated_at]},
  conflict_target: [:name]
)

# --- ML Model catalogue entries (logic in external ML service; no DSL text) ---

ml_model_entries = [
  %{
    name: "BillingPatternAnomalyModel",
    description: "Detects statistically unusual billing sequences relative to provider peer group",
    entry_type: "ML Model",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "ProviderBehaviorRiskModel",
    description: "Scores provider fraud likelihood using tenure, claim volume, and amount patterns",
    entry_type: "ML Model",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "DiagnosisProcedureConsistencyModel",
    description: "AI model that verifies alignment of diagnosis codes with billed procedure codes",
    entry_type: "ML Model",
    status: "Active",
    editable: false,
    removable: false,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  ml_model_entries,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# --- New BA Rules: DSL text stored in business_rules table ---

new_ba_rules = [
  %{
    name: "HighValueClaim",
    rule_text:
      """
      RULE high_value_claim
      DESCRIPTION "Claims exceeding $50,000 require manual review before payment"
      WHEN financial.claim_amount > 50000
      THEN REQUIRE_REVIEW "Claim exceeds high-value threshold — manual approval required"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "UnauthorizedProcedure",
    rule_text:
      """
      RULE unauthorized_procedure
      DESCRIPTION "High-value claim submitted without a valid authorization number"
      WHEN authorization.authorization_number IS NULL
           AND financial.claim_amount > 5000
      THEN REJECT "High-value claim lacks required authorization"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "NewProviderLargeSubmission",
    rule_text:
      """
      RULE new_provider_large_submission
      DESCRIPTION "Large claim from a provider credentialed less than 90 days ago"
      WHEN provider.tenure_days < 90
           AND financial.claim_amount > 10000
      THEN REQUIRE_REVIEW "Large submission from newly credentialed provider"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "SuspiciouslyLowCharge",
    rule_text:
      """
      RULE suspicious_low_charge
      DESCRIPTION "Charge below $5 may indicate billing manipulation or data error"
      WHEN financial.claim_amount < 5
      THEN FLAG_FRAUD "Suspiciously low charge — possible billing manipulation"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "HighComplexityERVisit",
    rule_text:
      """
      RULE high_complexity_er_visit
      DESCRIPTION "High-complexity ER visit (99285) with elevated charges requires clinical review"
      WHEN service_lines.0.procedure_code = "99285"
           AND financial.claim_amount > 10000
      THEN REQUIRE_REVIEW "High-complexity ER — clinical validation required"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  BusinessRule,
  new_ba_rules,
  on_conflict: {:replace, [:rule_text, :active, :updated_at]},
  conflict_target: [:name]
)

# --- New BA Rule catalogue entries (matching business_rules rows above) ---

new_ba_catalogue_entries = [
  %{
    name: "HighValueClaim",
    description: "Flag claims exceeding $50,000 for mandatory manual review before payment",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "UnauthorizedProcedure",
    description: "Reject high-value claims ($5k+) that have no authorization number on file",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "NewProviderLargeSubmission",
    description: "Review large submissions ($10k+) from providers credentialed fewer than 90 days",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "SuspiciouslyLowCharge",
    description: "Flag claims billed under $5 as potential billing manipulation or data error",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "HighComplexityERVisit",
    description: "Require clinical review for high-complexity ER visits (99285) exceeding $10,000",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  new_ba_catalogue_entries,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# --- Taxonomy Validation Rules ---

taxonomy_ba_rules = [
  %{
    name: "MissingProviderTaxonomy",
    rule_text:
      """
      RULE missing_provider_taxonomy
      DESCRIPTION "Flag claims missing provider taxonomy code for specialty verification"
      WHEN billing_provider.taxonomy IS NULL
           AND financial.claim_amount > 1000
      THEN REQUIRE_REVIEW "Provider taxonomy code missing — cannot validate specialty"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "TaxonomyMismatchNewProvider",
    rule_text:
      """
      RULE taxonomy_mismatch_new_provider
      DESCRIPTION "New provider with missing taxonomy on high-value claim is high risk"
      WHEN billing_provider.taxonomy IS NULL
           AND provider.tenure_days < 90
           AND financial.claim_amount > 5000
      THEN FLAG_FRAUD "New provider with no taxonomy code submitting high-value claim"
      END
      """
      |> String.trim(),
    active: true,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  BusinessRule,
  taxonomy_ba_rules,
  on_conflict: {:replace, [:rule_text, :active, :updated_at]},
  conflict_target: [:name]
)

taxonomy_ba_catalogue_entries = [
  %{
    name: "MissingProviderTaxonomy",
    description: "Flag claims over $1,000 that are missing the provider taxonomy code from PRV segment",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "TaxonomyMismatchNewProvider",
    description: "Flag new providers (<90 days) submitting $5k+ claims without taxonomy as potential fraud",
    entry_type: "BA Rule",
    status: "Active",
    editable: true,
    removable: true,
    redundant: false,
    db_access: false,
    inserted_at: now,
    updated_at: now
  }
]

Repo.insert_all(
  RuleCatalogue,
  taxonomy_ba_catalogue_entries,
  on_conflict: {:replace, [:description, :status, :updated_at]},
  conflict_target: [:name]
)

# --- NPPES Refresh Config (ensure default row exists) ---
RefreshConfig.get_or_create()

# --- Admin user ---
alias MedicaidClaimsChecker.Accounts

unless Accounts.get_user_by_email("admin@example.com") do
  {:ok, _} =
    Accounts.register_admin(%{
      email: "admin@example.com",
      password: "AdminPassword123!",
      username: "admin",
      first_name: "Admin",
      last_name: "User"
    })

  IO.puts("Admin user created: admin@example.com / AdminPassword123!")
end
