defmodule MedicaidClaimsChecker.X12.Codes.ClaimFilingIndicators do
  @moduledoc """
  CLM Segment Claim Filing Indicator Code Lookups

  Maps X12 claim filing indicator codes (CLM05-01) to descriptions.
  Identifies the type of insurance or payment program.
  """

  @doc """
  Get description for claim filing indicator code.
  """
  def lookup(code) do
    case code do
      "09" -> "Self Pay"
      "11" -> "Other Non-Federal Programs"
      "12" -> "Preferred Provider Organization (PPO)"
      "13" -> "Point of Service (POS)"
      "14" -> "Exclusive Provider Organization (EPO)"
      "15" -> "Indemnity Insurance"
      "16" -> "Health Maintenance Organization (HMO) Medicare Risk"
      "AM" -> "Automobile Medical"
      "BL" -> "Blue Cross/Blue Shield"
      "CH" -> "CHAMPUS"
      "CI" -> "Commercial Insurance Co."
      "DS" -> "Disability"
      "FI" -> "Federal Employees Program"
      "HM" -> "Health Maintenance Organization"
      "LM" -> "Liability Medical"
      "MA" -> "Medicare Part A"
      "MB" -> "Medicare Part B"
      "MC" -> "Medicaid"
      "OF" -> "Other Federal Program"
      "TV" -> "Title V"
      "VA" -> "Veterans Affairs Plan"
      "WC" -> "Workers Compensation Health Claim"
      "ZZ" -> "Mutually Defined"
      _ -> code
    end
  end
end
