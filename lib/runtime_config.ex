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
      ],
      acls: [
        # one per group, attached to what is published in it, so its moderators can moderate those objects through a single shared ACL rather than grants on each one
        group_mods_may_moderate: %{
          id: "6R0VPM0DERAT0RSMAYM0DERATE",
          name: l("Group moderators may moderate"),
          stereotype: true
        },
        # one per group, attached to what is published in a members-only group, so its members and moderators can participate through a single shared ACL rather than one made for each post
        group_members_may_participate: %{
          id: "6R0VPMEMBERSMAYPART1C1PATE",
          name: l("Group members may participate"),
          stereotype: true
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

    # What the audience chosen for a post in a group becomes (a group's visibility is who can see the GROUP, not its posts, so only these cap them). Each key is a chosen audience, or `{:not_in, audiences}` for any other; an audience no key matches is kept.
    prevent_federating_unfederated_group_caps = %{
      "public" => "nonfederated",
      "public:preview" => "nonfederated:preview",
      "unlisted" => "nonfederated:unlisted"
    }

    prevent_revealing_hidden_group_caps = %{
      {:not_in, ["private", "moderators"]} => "members:private"
    }

    config :bonfire_classify,
      # `l/1` marks the preset/toggle `label`/`description`/`help` for extraction, but `config/0` runs
      # once at boot under the default locale, so the stored value is effectively the untranslated
      # msgid. Per-request translation happens at render via `localise_tree/3` in
      # `Bonfire.UI.Groups.GroupBoundaryEditorLive`.
      #
      # Layer 1 presets for group creation. Each maps intent-named audience shapes onto the
      # four underlying boundary dimensions, plus default states for the Layer 2 toggles.
      # Picking one yields a complete, working group — users can stop at Layer 1 and ship.
      #
      # layer2_locked: lists which Layer 2 toggles cannot be changed for this preset.
      # Only `open_network` federates for now, so :federate is locked on every preset.
      # The audiences of posts in a group, see `Bonfire.Classify.Boundaries.list_post_audiences/1` and `post_boundary_options/3`
      group_post_audiences: %{
        # caps, by the scope of the group's own visibility
        caps: %{
          # a hidden group (its `members:private` visibility grants nothing to match on, so reads back as nil): a post seen outside it would reveal it
          nil => prevent_revealing_hidden_group_caps,
          # the same group as its `members:private` slug, as the settings editor has it (so it offers only the defaults publishing keeps)
          "members" => prevent_revealing_hidden_group_caps,
          # an unfederated group: a federated post stops federating, keeping its kind
          "local" => prevent_federating_unfederated_group_caps,
          "nonfederated" => prevent_federating_unfederated_group_caps
        },
        # offered after the group's default and its broadest audience (the first `default_content_visibility` slug, through the caps)
        also_offered: ["members:private", "moderators"],
        # posts with these also get the group's members ACL
        with_members_acl: ["members:private"],
        # when neither the chosen audience nor the group's default is one: only the group's moderators (and the author)
        fail_closed: "moderators",
        # when the group can't be resolved at all, so its caps are unknown: only the author
        unresolved: "private"
      },
      # Preselected in the new-group form.
      group_default_preset: "local_community",
      # Layer 2 toggle definitions — rendered in this order.
      layer2_toggles: [
        # TODO: the :discoverable toggle is withheld until it can flip one bit instead of two. Visibility roles encode `see` and `read` INDEPENDENTLY (`:interact` = see+read, `:preview_discover` = see only, `:unlisted_read` = read only), but this toggle maps to a single target role and so rewrote both: unticking it on a `*:preview` group (see, members-only content) moved it to `*:unlisted`, granting read to everyone. Fixing it means preserving the `read` bit, which needs a decision about the corner where neither bit is left, since there is no per-scope slug for that, only `members:private`. Until then a group's visibility is edited directly at Layer 3. See the group federation plan.
        # %{
        #   key: :discoverable,
        #   label: l("Discoverable in group listings"),
        #   help: l("Group shows in public lists and search.")
        # },
        %{
          key: :federate,
          label: l("Federate to other instances"),
          help: l("Reachable from other fediverse servers.")
        },
        %{
          key: :joins_need_approval,
          label: l("Require approval to join"),
          help: l("Moderators review each join request. Posts are a separate setting.")
        },
        %{
          key: :nonmembers_may_post,
          label: l("Non-members can post"),
          help: l("People who have not joined can post too, as far as the group's reach allows.")
        }
      ],
      group_preset_order: [
        "open_network",
        "local_community",
        # replaced by `local_community` now that `open_network` federates; still in `group_presets` so groups already on it keep it (and its card shows in their settings)
        # "public_local_community",
        "announcement_channel",
        "private_club"
        # "secret_group"  # uncomment when invite-only member management is ready
      ],
      group_presets: %{
        "open_network" => %{
          label: l("Open network"),
          description:
            l("Public and federated: anyone anywhere can find, join, and participate."),
          icon: "ph:globe-duotone",
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public",
          # only `federate`, since switching it off un-federates the one federated preset. Approval on makes it a public group that reviews joins
          layer2_locked: [:federate]
        },
        # Each preset declares its FINAL dimension slugs. Layer 2 toggle initial states
        # are derived from these by `Bonfire.UI.Groups.GroupBoundaryEditorLive`.
        "local_community" => %{
          label: l("Local community"),
          description:
            l(
              "Anyone can find this group, but only users of this instance can join and participate."
            ),
          icon: "ph:campfire-duotone",
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors",
          default_content_visibility: "local",
          layer2_locked: [:federate]
        },
        "public_local_community" => %{
          label: l("Public local community"),
          description:
            l("Visible to everyone. Users of this instance are free to join and participate."),
          icon: "ph:campfire-duotone",
          membership: "local:members",
          # "Visible to everyone": see AND read, matching this preset's public `default_content_visibility`. `private_club` is the one that wants a `*:preview` slug, where only members read the content.
          visibility: "nonfederated",
          participation: "local:contributors",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate]
        },
        "announcement_channel" => %{
          label: l("Announcement channel"),
          description:
            l("Public channel where only moderators post, and anyone can follow and interact."),
          icon: "ph:megaphone-duotone",
          membership: "invite_only",
          # "Public channel": everyone sees AND reads it. The `*:preview` slugs mean "can see the group exists, but only members can read content", which is the private_club shape, not this one. Only moderators posting is the `participation` dimension's job, and `invite_only` membership is what keeps the members circle closed.
          visibility: "nonfederated",
          # TODO: global once federation is enabled
          participation: "moderators",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate, :nonmembers_may_post]
        },
        "private_club" => %{
          label: l("Private club"),
          description:
            l(
              "Users of this instance can find the group and request to join, but content is for group members-only."
            ),
          icon: "ph:lock-duotone",
          membership: "on_request",
          visibility: "local:preview",
          # TODO: `preview` (the global-scope one) once federation is enabled
          participation: "group_members",
          default_content_visibility: "members:private",
          layer2_locked: [:federate, :nonmembers_may_post]
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
        #   layer2_locked: [:federate, :discoverable, :joins_need_approval, :nonmembers_may_post]
        # }
      }
  end
end
