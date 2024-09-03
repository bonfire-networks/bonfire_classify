defmodule Bonfire.Classify.Tree do
  @moduledoc "A mixin used to record parent/child relationships between categories (eg. a topic that belongs to a group) and between objects and categories (eg. a post was published in a topic)"
  use Needle.Mixin,
    otp_app: :bonfire_classify,
    source: "category_tree"

  # to query trees:
  use EctoMaterializedPath
  use Arrows
  import Untangle

  alias Bonfire.Common.Types
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Tree
  alias Needle.Pointer
  alias Needle.Changesets
  alias Ecto.Changeset

  mixin_schema do
    # parent is always a category (keeping in mind that means one of: Group, Topic, Label...)
    belongs_to(:parent, Category, foreign_key: :parent_id)
    # custodian can be for example a user or category
    belongs_to(:custodian, Pointer, foreign_key: :custodian_id)
    # Kept updated by triggers. Total replies = direct replies + nested replies.
    field(:direct_children_count, :integer, default: 0)
    field(:nested_children_count, :integer, default: 0)
    # default is important here
    field(:path, EctoMaterializedPath.ULIDs, default: [])
  end

  # @cast [:custodian_id]
  @cast [:parent_id, :custodian_id]
  # @required [:parent_id]

  def put_tree(changeset, custodian, parent)

  def put_tree(changeset, %Category{} = custodian_group, nil) do
    put_tree(changeset, custodian_group, custodian_group)
  end

  def put_tree(changeset, nil, %Category{} = custodian_group) do
    put_tree(changeset, custodian_group, custodian_group)
  end

  def put_tree(changeset, custodian, nil) do
    changeset
    |> Changesets.put_assoc(:tree, new_tree(changeset, custodian))
  end

  def put_tree(changeset, custodian, %{tree: %Tree{} = parent_tree} = _parent_category) do
    put_tree(changeset, custodian, parent_tree)
  end

  def put_tree(changeset, custodian, %Tree{} = parent_tree) do
    changeset
    |> Changesets.put_assoc(:tree, %{
      custodian_id: Types.uid!(custodian),
      parent_id: Types.uid!(parent_tree)
    })
    |> Changeset.update_change(
      :tree,
      &Tree.make_child_of(&1, parent_tree)
    )
  end

  defp new_tree(changeset, custodian) do
    %Tree{id: Types.uid!(changeset), custodian_id: Types.uid(custodian)}
  end

  def changeset(tree \\ %Tree{}, attrs)

  def changeset(
        tree,
        %{parent: %{tree: %{id: _} = parent}} = attrs
      ) do
    # EctoMaterializedPath needs the Tree struct
    changeset(tree, Map.put(attrs, :parent, parent))
  end

  def changeset(
        tree,
        %{parent: %Tree{id: parent_id, custodian_id: parent_custodian_id} = parent} = attrs
      ) do
    debug(
      "Tree - recording parent #{inspect(parent_id)} in custodian #{inspect(attrs[:custodian_id])}"
    )

    attrs
    |> Map.put(:parent_id, parent_id)
    |> Map.put(
      :custodian_id,
      Types.uid!(
        attrs[:custodian] || attrs[:custodian_id] || attrs[:custodian_id] || parent_custodian_id
      )
    )
    |> Changeset.cast(tree, ..., @cast)
    # |> Changeset.validate_required(@required)
    |> Changeset.assoc_constraint(:parent)
    # set tree path (powered by EctoMaterializedPath)
    |> make_child_of(parent)
  end

  def changeset(_tree, %{parent_id: parent_id} = attrs)
      when not is_nil(parent_id) do
    error(
      attrs,
      "you must pass the Tree struct of the category, an ID is not enough"
    )

    raise "Could not record the tree."
  end

  # for top-level posts only
  def changeset(tree, attrs) do
    debug("Tree - recording a top level thing")

    attrs
    |> Map.put(
      :custodian_id,
      Types.uid!(attrs[:custodian] || attrs[:custodian_id] || attrs[:custodian_id])
    )
    |> Changeset.cast(tree, ..., @cast)
  end
end

defmodule Bonfire.Classify.Tree.Migration do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration
  alias Bonfire.Classify.Tree

  @table Tree.__schema__(:source)
  # counts in this case are stored in same table as data being counted
  @trigger_table @table

  def create_fun,
    do: """
    create or replace function "#{@table}_change" ()
    returns trigger
    language plpgsql
    as $$
    declare
    begin
      if (TG_OP = 'INSERT') then
        -- Increment the number of direct children of this category
        update "#{@table}"
          set direct_children_count = direct_children_count + 1
          where id = NEW.parent_id;
        -- Increment the number of nested children
        update "#{@table}"
          set nested_children_count = nested_children_count + 1
          where id  = NEW.custodian_id
            and id != NEW.parent_id;
        -- Increment the number of nested children of each of the parents in the tree path,
        -- except when the path id is the same as NEW.id, or was already updated above
        update "#{@table}"
          set nested_children_count = nested_children_count + 1
          where id  = ANY(NEW.path)
            and id != NEW.id
            and id != NEW.parent_id
            and id != NEW.custodian_id;
        return NULL;
      elsif (TG_OP = 'DELETE') then
        -- Decrement the number of children of the category
        update "#{@table}"
          set direct_children_count = direct_children_count - 1
          where id = OLD.parent_id;
        -- Decrement the number of nested children of the category
        update "#{@table}"
          set nested_children_count = nested_children_count - 1
          where id  = OLD.custodian_id
            and id != OLD.parent_id;
        -- Decrement the number of nested children of each of the parents in the tree path, except for the path ids that were already updated above
        update "#{@table}"
          set nested_children_count = nested_children_count - 1
          where id  = ANY(OLD.path)
            and id != OLD.parent_id
            and id != OLD.custodian_id;
        return null;
      end if;
    end;
    $$;
    """

  def create_trigger,
    do: """
    create trigger "#{@table}_trigger"
    after insert or delete on "#{@trigger_table}"
    for each row execute procedure "#{@table}_change"();
    """

  @drop_fun ~s[drop function if exists "#{@table}_change" CASCADE]
  @drop_trigger ~s[drop trigger if exists "#{@table}_trigger" ON "#{@trigger_table}"]

  def migrate_functions do
    # this has the appearance of being muddled, but it's not
    Ecto.Migration.execute(create_fun(), @drop_fun)
    # to replace if changed
    Ecto.Migration.execute(@drop_trigger, @drop_trigger)
    Ecto.Migration.execute(create_trigger(), @drop_trigger)
  end

  # create_tree_table/{0, 1}

  defp make_tree_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_mixin_table unquote(@table) do
        Ecto.Migration.add(
          :parent_id,
          Needle.Migration.strong_pointer(Bonfire.Classify.Category)
        )

        Ecto.Migration.add(:custodian_id, Needle.Migration.strong_pointer())
        Ecto.Migration.add(:path, {:array, :uuid}, default: [], null: false)

        Ecto.Migration.add(:direct_children_count, :bigint,
          null: false,
          default: 0
        )

        Ecto.Migration.add(:nested_children_count, :bigint,
          null: false,
          default: 0
        )

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_tree_table(), do: make_tree_table([])
  defmacro create_tree_table(do: {_, _, body}), do: make_tree_table(body)

  # drop_tree_table/0

  def drop_tree_table(), do: drop_mixin_table(Tree)

  # migrate_tree/{0, 1}

  defp mcd(:up) do
    make_tree_table([])

    # Ecto.Migration.flush()
    # migrate_functions() # put this in your app's migration instead
  end

  defp mcd(:down) do
    quote do
      Bonfire.Classify.Tree.Migration.migrate_functions()
      Bonfire.Classify.Tree.Migration.drop_tree_table()
    end
  end

  defmacro migrate_tree() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mcd(:up)),
        else: unquote(mcd(:down))
    end
  end

  defmacro migrate_tree(dir), do: mcd(dir)
end
