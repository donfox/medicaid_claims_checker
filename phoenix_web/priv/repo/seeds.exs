alias MedicaidClaimsChecker.Repo
alias MedicaidClaimsChecker.Claims.BusinessRule
alias MedicaidClaimsChecker.Claims.RuleCatalogue
alias MedicaidClaimsChecker.Nppes.RefreshConfig

now = DateTime.utc_now() |> DateTime.truncate(:second)

# NPPES providers are not seeded: test claims use real NPIs from the NPPES
# registry the app imports (Nppes.Importer / Settings → NPPES refresh).

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
    active: false,
    inserted_at: now,
    updated_at: now
  },
  %{
    name: "WeekendOfficeVisit",
    rule_text:
      """
      RULE weekend_office_visit
      DESCRIPTION \"Office visit on weekend with elevated amount\"
      WHEN financial.claim_amount > 500
           AND claim_details.facility_type_code IS NULL
           AND EXISTS line IN service_lines
               WHERE is_weekend(line.date_of_service) AND line.place_of_service = \"11\"
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
    description: "Rejects claims where any service line is dated before 1900",
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
    description:
      "Detects duplicate claim submissions within 30 days for the same member and provider",
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
    description:
      "Validates provider NPI exists in the NPPES national registry and was active on the date of service",
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
    description:
      "Flag high-value claims over $50,000 for manual review — inactive, duplicates HighValueClaim",
    entry_type: "BA Rule",
    status: "Inactive",
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
    description:
      "Retired 2026-10-19. Looked for inpatient billing with an outpatient place of service on one claim, " <>
        "but no 837 carries both (837P has a place of service, 837I a bill type). Kept for the record.",
    entry_type: "BA Rule",
    status: "Retired",
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
    description: "Rejects claims where any service line's date of service has not yet occurred",
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
      "Rejects claims where any service line is dated before 1900 (future dates are FutureServiceDate)"
      WHEN EXISTS line IN service_lines WHERE is_date_before(line.date_of_service, "1900-01-01")
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
      "Rejects claims where any service line's date of service has not yet occurred"
      WHEN EXISTS line IN service_lines WHERE is_future_date(line.date_of_service)
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
    description:
      "Detects statistically unusual billing sequences relative to provider peer group",
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
    description:
      "Scores provider fraud likelihood using tenure, claim volume, and amount patterns",
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
    description:
      "AI model that verifies alignment of diagnosis codes with billed procedure codes",
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
      WHEN financial.claim_amount > 10000
           AND EXISTS line IN service_lines
             WHERE line.procedure_code IS NOT NULL AND line.procedure_code = "99285"
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
    description:
      "Review large submissions ($10k+) from providers credentialed fewer than 90 days",
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
    description:
      "Require clinical review for high-complexity ER visits (99285) exceeding $10,000",
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
    description:
      "Flag claims over $1,000 that are missing the provider taxonomy code from PRV segment",
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
    description:
      "Flag new providers (<90 days) submitting $5k+ claims without taxonomy as potential fraud",
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

# --- First admin user ---
# Created only while the database has no admin, so it never comes back once
# real admins exist. SEED_ADMIN_EMAIL and SEED_ADMIN_USERNAME choose the
# account. Development and tests use a known password; anywhere else it comes
# from SEED_ADMIN_PASSWORD, or a random one is printed once.
alias MedicaidClaimsChecker.Accounts

unless Enum.any?(Accounts.list_users(), & &1.is_admin) do
  dev_or_test? = Code.ensure_loaded?(Mix) and Mix.env() in [:dev, :test]
  email = System.get_env("SEED_ADMIN_EMAIL") || "admin@example.com"
  username = System.get_env("SEED_ADMIN_USERNAME") || "admin"

  password =
    System.get_env("SEED_ADMIN_PASSWORD") ||
      if(dev_or_test?,
        do: "AdminPassword123!",
        else: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

  case Accounts.register_admin(%{
         email: email,
         password: password,
         username: username,
         first_name: "Admin",
         last_name: "User"
       }) do
    {:ok, _} ->
      IO.puts("Admin user created: #{email} / #{password}")

    {:error, changeset} ->
      IO.puts(
        "No admin created: #{inspect(changeset.errors)}. " <>
          "Set SEED_ADMIN_EMAIL and SEED_ADMIN_USERNAME to unused values, or make an existing user an admin."
      )
  end
end
