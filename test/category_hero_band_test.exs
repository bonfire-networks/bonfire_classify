if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Classify.CategoryHeroBandTest do
    @moduledoc "A category's hero has a band in its colour only when it has set one."
    use Bonfire.Classify.DataCase, async: false
    use Surface.LiveViewTest
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo

    alias Bonfire.Classify.Appearance
    alias Bonfire.Classify.Categories

    defp hero(category) do
      {:ok, category} = Categories.get(id(category), [:default, skip_boundary_check: true])
      assigns = %{category: category}

      render_surface do
        ~F"""
        <Bonfire.Classify.Web.CategoryHeroLive category={@category} subcategories={[]} />
        """
      end
    end

    test "has no band with no colour set, and one in the swatch once it is" do
      user = Bonfire.Me.Fake.fake_user!()
      label = fake_category!(user, nil, %{type: :label})

      refute hero(label) =~ "label_hero_band"

      {:ok, _} = Appearance.set_colour(label, "amber", current_user: user)

      html = hero(label)
      assert html =~ "label_hero_band"
      assert html =~ "topic-amber"
    end

    test "shows the picked icon with no uploaded image, and none without one picked" do
      user = Bonfire.Me.Fake.fake_user!()
      label = fake_category!(user, nil, %{type: :label})

      refute hero(label) =~ "label_hero_icon"

      {:ok, _} = Appearance.set_icon(label, "ph:baby-fill", current_user: user)

      html = hero(label)
      assert html =~ "label_hero_icon"
      assert html =~ "ph:baby-fill"
    end

    # uploads are resized with vips, which CI doesn't have
    @tag Bonfire.Common.RuntimeConfig.skip_in_ci()
    test "shows the uploaded image, not the picked icon" do
      user = Bonfire.Me.Fake.fake_user!()
      label = fake_category!(user, nil, %{type: :label})
      {:ok, _} = Appearance.set_icon(label, "ph:baby-fill", current_user: user)

      assert hero(label) =~ "label_hero_icon"

      {:ok, image} =
        Bonfire.Files.Simulation.fake_upload(
          Bonfire.Files.Simulation.image_file(),
          Bonfire.Files.ImageUploader,
          user
        )

      {:ok, _} =
        Categories.update(user, label, %{"profile" => %{"image" => image, "image_id" => image.id}})

      html = hero(label)
      refute html =~ "label_hero_icon"
      assert html =~ "background-image"
    end
  end
end
