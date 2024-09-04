defmodule Bonfire.Classify.SharedDataDanceCase do
  use ExUnit.CaseTemplate
  import Tesla.Mock
  import Untangle
  import Bonfire.UI.Common.Testing.Helpers
  import Bonfire.Classify.Simulate
  alias Bonfire.Common.TestInstanceRepo

  def fancy_fake_category!(creator, opts \\ []) do
    # repo().delete_all(ActivityPub.Object)
    # id = Needle.UID.generate()
    category = fake_category!(creator, opts)
    display_username = Bonfire.Me.Characters.display_username(category, true)

    [
      category: category,
      username: display_username,
      url_on_local:
        "@" <>
          display_username <>
          "@" <>
          Bonfire.Common.URIs.base_domain(Bonfire.Me.Characters.character_url(category)),
      canonical_url: Bonfire.Me.Characters.character_url(category),
      friendly_url:
        "#{Bonfire.Common.URIs.base_url()}#{Bonfire.Common.URIs.path(category) || "/group/#{display_username}"}"
    ]
  end

  def fancy_fake_category_on_test_instance(creator, opts \\ []) do
    TestInstanceRepo.apply(fn -> fancy_fake_category!(creator, opts) end)
  end

  setup_all tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    on_exit(fn ->
      # this callback needs to checkout its own connection since it
      # runs in its own process
      # :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
      # Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

      # Object.delete(actor1)
      # Object.delete(actor2)
      :ok
    end)

    [
      local: fancy_fake_user!("Local"),
      remote: fancy_fake_user_on_test_instance()
    ]
  end
end
