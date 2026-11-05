if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.GroupSearchTest do
    @moduledoc "`Categories.search_groups/2` with no search backend: it returns nil, so each caller keeps its own fallback."
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils
    @moduletag :backend

    alias Bonfire.Classify.Categories

    test "with no search backend it returns nil" do
      user = Bonfire.Me.Fake.fake_user!()

      Bonfire.Classify.Simulate.fake_group!(user, %{
        name: "Zebrafinch makers",
        membership: "open",
        visibility: "global",
        participation: "anyone"
      })

      # `ProcessTree` treats a stored nil as unset, so `false` stands for "no adapter"
      Process.put([:bonfire_search, :adapter], false)

      assert is_nil(Categories.search_groups("zebrafinch", current_user: user))
    end
  end
end
