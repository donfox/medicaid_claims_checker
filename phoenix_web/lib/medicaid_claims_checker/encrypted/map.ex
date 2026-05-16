defmodule MedicaidClaimsChecker.Encrypted.Map do
  use Cloak.Ecto.Map, vault: MedicaidClaimsChecker.Vault
end
