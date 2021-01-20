# check that this extension is configured
defmodule Bonfire.Classify.Simulate do
  import Bonfire.Common.Simulation

  alias Bonfire.Classify.Categories

  ### Start fake data functions

  def category(base \\ %{}) do
    base
    # |> Map.put_new_lazy(:id, &uuid/0)
    |> Map.put_new_lazy(:name, &name/0)
    |> Map.put_new_lazy(:note, &summary/0)
    |> Map.put_new_lazy(:is_public, &truth/0)
    |> Map.put_new_lazy(:is_disabled, &falsehood/0)
  end

  def fake_category!(user, parent_category \\ nil, overrides \\ %{})

  def fake_category!(user, nil, overrides) do
    with {:ok, category} <- Categories.create(user, category(overrides)) do
      category
    else _ ->
      fake_category!(user, nil, overrides)
    end
  end

  def fake_category!(user, parent_category, overrides) do
    {:ok, category} =
      Categories.create(user, category(Map.put(overrides, :parent_category, parent_category)))

    category
  end
end
