defmodule Bonfire.Classify.Dance.GroupTest do
  use Bonfire.Classify.ConnCase, async: false
  use Bonfire.Classify.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Classify.SharedDataDanceCase
  #  import AssertValue

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  @tag :test_instance
  test "can lookup group actors from AP API with username, AP ID and with friendly URL",
       context do
    # lookup 3 separate users to be sure
    creator = context[:remote][:user]

    remote = fancy_fake_category_on_test_instance(creator)

    {:ok, %Bonfire.Classify.Category{} = object} =
      AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

    assert object.profile.name == remote[:category].profile.name

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_username(remote[:username])
    assert actor.data["type"] == "Group"

    remote = fancy_fake_category_on_test_instance(creator)

    assert {:ok, %Bonfire.Classify.Category{} = object} =
             AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

    assert object.profile.name == remote[:category].profile.name

    remote = fancy_fake_category_on_test_instance(creator)

    assert {:ok, %Bonfire.Classify.Category{} = object} =
             AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

    assert object.profile.name == remote[:category].profile.name
  end
end
