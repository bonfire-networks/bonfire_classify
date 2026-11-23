if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.AppearanceTest do
    @moduledoc "The colour and icon of a group, topic or label: its own setting, else its parent's (colour only), else a swatch hashed from its id."
    use Bonfire.Classify.DataCase, async: false
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Classify.Appearance
    alias Bonfire.Classify.Category
    alias Bonfire.Common.Swatches

    setup do
      user = Bonfire.Me.Fake.fake_user!()
      {:ok, user: user}
    end

    # `Settings.get(scope: …)` reads what is on the struct, so what a put changed is loaded again, with the parents' settings
    defp reload(category) do
      repo().get!(Category, id(category))
      |> repo().preload([:settings, parent_category: [:settings, parent_category: [:settings]]])
    end

    defp put_colour(user, category, swatch),
      do:
        {:ok, _} =
          Bonfire.Common.Settings.put([:ui, :colour], swatch, scope: category, current_user: user)

    defp other_than(swatch), do: Enum.find(Swatches.names(), &(&1 != swatch))

    describe "colour/1" do
      test "a category's own colour wins over its parent's", %{user: user} do
        parent = fake_group!(user)
        topic = fake_category!(user, parent, %{type: :topic})
        put_colour(user, parent, "red")
        put_colour(user, topic, "violet")

        assert Appearance.colour(reload(topic)) == "violet"
      end

      test "without its own, a topic takes its parent's, and its grandparent's through it", %{
        user: user
      } do
        group = fake_group!(user)
        topic = fake_category!(user, group, %{type: :topic})
        subtopic = fake_category!(user, topic, %{type: :topic})
        put_colour(user, group, "teal")

        assert Appearance.colour(reload(topic)) == "teal"
        assert Appearance.colour(reload(subtopic)) == "teal"

        put_colour(user, topic, "pink")
        assert Appearance.colour(reload(subtopic)) == "pink"
        assert Appearance.colour(reload(group)) == "teal"
      end

      test "with none set anywhere, the swatch hashed from its id, the same every time", %{
        user: user
      } do
        topic = fake_category!(user, nil, %{type: :topic})
        topic = reload(topic)

        assert Appearance.colour(topic) == Swatches.from_seed(id(topic))
        assert Appearance.colour(topic) == Appearance.colour(topic)
        assert Swatches.valid?(Appearance.colour(topic))
      end

      test "an unloaded :settings (and parent) falls through to the hash, without raising", %{
        user: user
      } do
        group = fake_group!(user)
        topic = fake_category!(user, group, %{type: :topic})
        put_colour(user, topic, "violet")
        put_colour(user, group, "red")

        bare = repo().get!(Category, id(topic))
        refute Ecto.assoc_loaded?(bare.settings)
        refute Ecto.assoc_loaded?(bare.parent_category)

        assert Appearance.colour(bare) == Swatches.from_seed(id(bare))

        # control: the same topic with its settings loaded does have its colour
        assert Appearance.colour(repo().preload(bare, :settings)) == "violet"
      end

      test "with its own settings loaded but no colour of its own, and its parent not loaded, the hashed swatch (not nil or a neutral one), though its parent has a colour",
           %{user: user} do
        group = fake_group!(user)
        topic = fake_category!(user, group, %{type: :topic})
        put_colour(user, group, "red")

        topic = repo().get!(Category, id(topic)) |> repo().preload(:settings)
        refute Ecto.assoc_loaded?(topic.parent_category)

        assert Appearance.colour(topic) == Swatches.from_seed(id(topic))

        # control: with the parent loaded, its colour is inherited
        assert Appearance.colour(reload(topic)) == "red"
      end

      test "a parent loaded without its settings through one assoc, and with them through the other, is read from the one that has them",
           %{user: user} do
        group = fake_group!(user)
        topic = fake_category!(user, group, %{type: :topic})
        put_colour(user, group, "teal")

        loaded =
          repo().get!(Category, id(topic))
          |> repo().preload([:settings, :parent_category])
          |> repo().preload(Appearance.preloads())

        refute Ecto.assoc_loaded?(loaded.parent_category.settings)
        assert Appearance.colour(loaded) == "teal"
      end

      test "a swatch name that is not in the set counts as unset", %{user: user} do
        group = fake_group!(user)
        topic = fake_category!(user, group, %{type: :topic})
        put_colour(user, group, "teal")
        put_colour(user, topic, "beige")

        assert Appearance.colour(reload(topic)) == "teal"
      end

      test "a colour in the instance's config is not any category's colour", %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic}) |> reload()
        hashed = Swatches.from_seed(id(topic))
        configured = other_than(hashed)

        Bonfire.Common.Config.put([:ui, :colour], configured)
        on_exit(fn -> Bonfire.Common.Config.put([:ui, :colour], nil) end)

        assert Appearance.colour(topic) == hashed
      end
    end

    describe "icon/1" do
      test "is the category's own icon, and nil when it has none or when settings are not loaded",
           %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic})
        assert Appearance.icon(reload(topic)) == nil

        assert {:ok, _} =
                 Appearance.set_icon(topic, "ph:music-notes-fill", current_user: user)

        assert Appearance.icon(reload(topic)) == "ph:music-notes-fill"
        assert Appearance.icon(repo().get!(Category, id(topic))) == nil
      end

      test "something that is not an icon name is refused", %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic})

        for bad <- ["not an icon", "<script>", "ph:", "music", nil] do
          assert {:error, _} = Appearance.set_icon(topic, bad, current_user: user)
        end

        assert Appearance.icon(reload(topic)) == nil
      end
    end

    describe "setting and resetting" do
      test "a colour and an icon set one after the other on the same struct are both kept, whatever settings it holds",
           %{user: user} do
        # settings loaded, and empty: what a category made a moment ago holds
        topic = fake_category!(user, nil, %{type: :topic}) |> repo().preload(:settings)
        assert topic.settings == nil

        assert {:ok, _} = Appearance.set_colour(topic, "violet", current_user: user)
        assert {:ok, _} = Appearance.set_icon(topic, "ph:music-notes-fill", current_user: user)

        reloaded = reload(topic)
        assert Appearance.own_colour(reloaded) == "violet"
        assert Appearance.icon(reloaded) == "ph:music-notes-fill"

        # and a reset of one leaves the other
        assert {:ok, _} = Appearance.reset_colour(topic, current_user: user)
        reloaded = reload(topic)
        assert Appearance.own_colour(reloaded) == nil
        assert Appearance.icon(reloaded) == "ph:music-notes-fill"
      end

      test "someone who can configure the category sets and resets its colour", %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic})

        assert Appearance.can_edit?(user, topic)
        assert {:ok, _} = Appearance.set_colour(topic, "violet", current_user: user)
        assert Appearance.colour(reload(topic)) == "violet"

        assert {:ok, _} = Appearance.reset_colour(topic, current_user: user)
        assert Appearance.colour(reload(topic)) == Swatches.from_seed(id(topic))
      end

      test "someone who cannot configure it is refused, and nothing changes", %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic})
        stranger = Bonfire.Me.Fake.fake_user!()

        refute Appearance.can_edit?(stranger, topic)

        assert {:error, _} =
                 catch_refusal(fn ->
                   Appearance.set_colour(topic, "violet", current_user: stranger)
                 end)

        assert Appearance.colour(reload(topic)) == Swatches.from_seed(id(topic))
      end

      test "a swatch name outside the set is refused", %{user: user} do
        topic = fake_category!(user, nil, %{type: :topic})
        assert {:error, _} = Appearance.set_colour(topic, "beige", current_user: user)
        assert Appearance.colour(reload(topic)) == Swatches.from_seed(id(topic))
      end
    end

    # a refused `Settings.put` raises `Bonfire.Fail`, which this turns into an error tuple
    defp catch_refusal(fun) do
      case fun.() do
        {:error, _} = error -> error
        other -> {:ok, other}
      end
    rescue
      e in Bonfire.Fail -> {:error, e}
    end
  end
end
