defmodule MedicaidClaimsChecker.X12.Codes.ReferenceQualifiers do
  @moduledoc """
  REF Segment Reference Identification Qualifier Code Lookups

  Maps X12 reference qualifier codes to descriptions.
  Used in REF (Reference Identification) segments.
  """

  @doc """
  Get description for REF reference identification qualifier code.
  """
  def lookup(code) do
    case code do
      "0B" -> "State License Number"
      "1A" -> "Blue Cross Provider Number"
      "1B" -> "Blue Shield Provider Number"
      "1C" -> "Medicare Provider Number"
      "1D" -> "Medicaid Provider Number"
      "1G" -> "Provider UPIN Number"
      "1H" -> "CHAMPUS Identification Number"
      "1J" -> "Facility ID Number"
      "4A" -> "Investigation Number"
      "6R" -> "Provider Control Number"
      "9A" -> "Repriced Claim Number"
      "9C" -> "Repriced Line Item Reference"
      "D3" -> "Membership Number"
      "D9" -> "Prior Authorization Number"
      "EA" -> "Medical Record Identification Number"
      "EI" -> "Employer ID Number"
      "F5" -> "Medicare Version Code"
      "F8" -> "Original Reference Number"
      "G1" -> "Referral Number"
      "G3" -> "Location Number"
      "LU" -> "Location Number"
      "SY" -> "Social Security Number"
      "X4" -> "Clinical Laboratory Improvement Amendment Number"
      "Y4" -> "Agency Claim Number"
      _ -> code
    end
  end
end
