defmodule MedicaidClaimsCheckerWeb.UseCases.EEdiFilesTest do
  @moduledoc "E1–E3: uploading .edi files."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  manifest_tests(~w(E1 E2 E3))
end
