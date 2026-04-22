defmodule Bonfire.Classify.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  NOTE: you can override this default config in your app's `runtime.exs`, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs()` line
  """
  def config do
    import Config

    # config :bonfire_classify,
    #   modularity: :disabled

    # Register the group_members circle stereotype used for group membership tracking
    config :bonfire_boundaries,
      circles: [
        group_members: %{
          id: "6R0VPMEMBERS1NACJRC1EN0W00",
          name: l("Group members"),
          stereotype: true,
          icon: "ph:users-three-duotone"
        },
        group_moderators: %{
          id: "3GR0VPM0DERAT0RSEMP0WERED2",
          name: l("Group moderators"),
          stereotype: true,
          icon: "ph:shield-duotone"
        }
      ]

    config :bonfire, :ui,
      activity_preview: [],
      object_preview: [
        {:topic, Bonfire.Classify.Web.Preview.CategoryLive},
        {Bonfire.Classify.Category, Bonfire.Classify.Web.Preview.CategoryLive}
      ],
      object_actions: [
        {Bonfire.Classify.Category, Bonfire.Classify.Web.CategoryActionsLive}
      ]

    config :bonfire_classify,
      # Layer 1 presets for group creation. Each maps intent-named audience shapes onto the
      # four underlying boundary dimensions, plus default states for the Layer 2 toggles.
      # Picking one yields a complete, working group — users can stop at Layer 1 and ship.
      #
      # layer2_locked: lists which Layer 2 toggles cannot be changed for this preset.
      # :federate is listed in every preset's layer2_locked until groups federation ships.
      group_default_preset: "private_club",
      # Layer 2 toggle definitions — rendered in this order.
      layer2_toggles: [
        %{
          key: :discoverable,
          label: l("Discoverable in group listings"),
          help: l("Group shows in public lists and search.")
        },
        %{
          key: :federate,
          label: l("Federate to other instances"),
          help: l("Reachable from other fediverse servers.")
        },
        %{
          key: :approval_required,
          label: l("Require approval to join"),
          help: l("Moderators review each join request.")
        },
        %{
          key: :anyone_posts,
          label: l("Anyone can post"),
          help: l("Any eligible user can post, not just members.")
        }
      ],
      group_preset_order: [
        # "open_network",  # uncomment when groups federation is ready
        "public_local_community",
        "announcement_channel",
        "private_club",
        "secret_group"
      ],
      group_presets: %{
        # Requires groups federation — disabled for now.
        # "open_network" => %{
        #   label: l("Open network"),
        #   description: l("Federated and open: anyone anywhere can find, join, and participate."),
        #   icon: "ph:globe-duotone",
        #   membership: "open",
        #   visibility: "global",
        #   participation: "anyone",
        #   default_content_visibility: "public",
        #   layer2_locked: [:discoverable, :approval_required, :anyone_posts, :federate],
        #   layer2_defaults: %{
        #     discoverable: true,
        #     federate: true,
        #     approval_required: false,
        #     anyone_posts: true
        #   }
        # },
        "public_local_community" => %{
          label: l("Public local community"),
          description:
            l("Visible to everyone. Users of this instance are free to join and participate."),
          icon: "ph:campfire-duotone",
          membership: "local:members",
          membership_open: "local:members",
          visibility: "nonfederated",
          participation: "group_members",
          participation_open: "local:contributors",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate],
          layer2_defaults: %{
            discoverable: true,
            federate: false,
            approval_required: false,
            anyone_posts: true
          }
        },
        "announcement_channel" => %{
          label: l("Announcement channel"),
          description:
            l("Public channel where only moderators post, and anyone can follow and interact."),
          icon: "ph:megaphone-duotone",
          membership: "invite_only",
          membership_open: "local:members",
          visibility: "nonfederated",
          # TODO: global once federation is enabled
          participation: "moderators",
          participation_open: "local:contributors",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate, :anyone_posts],
          layer2_defaults: %{
            discoverable: true,
            federate: false,
            approval_required: false,
            anyone_posts: false
          }
        },
        "private_club" => %{
          label: l("Private club"),
          description:
            l(
              "Group is visible and discoverable, but content is for members-only. Anyone can request to join."
            ),
          icon: "heroicons-solid:lock-closed",
          membership: "on_request",
          membership_open: "local:members",
          visibility: "local:discoverable",
          # TODO: global:discoverable once federation is enabled
          participation: "group_members",
          participation_open: "local:contributors",
          default_content_visibility: "members:private",
          layer2_locked: [:federate, :anyone_posts],
          layer2_defaults: %{
            discoverable: true,
            federate: false,
            approval_required: true,
            anyone_posts: false
          }
        }
        # TODO: enable when we add a way for mods to add members
        # "secret_group" => %{ 
        #   label: l("Secret group"),
        #   description: l("Hidden from listings. Invite-only. Nothing leaves the group."),
        #   icon: "ph:eye-slash-duotone",
        #   membership: "invite_only",
        #   visibility: "members:private",
        #   participation: "group_members",
        #   default_content_visibility: "members:private",
        #   layer2_locked: [:federate, :discoverable, :approval_required, :anyone_posts],
        #   layer2_defaults: %{
        #     discoverable: false,
        #     federate: false,
        #     approval_required: false,
        #     anyone_posts: false
        #   }
        # }
      }
  end
end
