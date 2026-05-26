defmodule :"Elixir.MedicaidClaimsChecker.Repo.Migrations.Update NPPES data URIs to current v2" do
  use Ecto.Migration

  def up do
    alter table(:nppes_refresh_config) do
      modify :download_url, :string, 
        default: "https://download.cms.gov/nppes/NPPES_Data_Dissemination_May_2026_V2.zip", 
        null: false
    end
  end

  def down do
    alter table(:nppes_refresh_config) do
      modify :download_url, :string, 
        default: "https://download.cms.gov/nppes/NPPES_Data_Dissemination_March_2026.zip", 
        null: false
    end
  end
end
