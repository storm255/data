defmodule DataWeb.SkillTaxonomy.RoleLive do
  @moduledoc """
  LiveView entry form for one role's skill-taxonomy cluster (see
  `design/SKILLS_TAXONOMY.md` §4) — the interactive counterpart to
  `Data.SkillTaxonomy.CsvImporter`. Builds and imports through the same
  `Data.SkillTaxonomy.RowBuilder` + `Data.SkillTaxonomy.CsvImporter.import/2`
  the CSV path uses, so the two entry paths can't drift apart.

  The `TerminusDB.Config` used comes from the connect session
  (`"terminus_config"`), falling back to `Data.TerminusDB.config/0` —
  this is the seam tests use to inject a stubbed adapter, the same
  pattern used throughout this app's TerminusDB-touching tests.
  """

  use DataWeb, :live_view

  alias Data.SkillTaxonomy.{CsvImporter, RoleLoader, RowBuilder}

  @impl true
  def mount(_params, session, socket) do
    config = Map.get(session, "terminus_config") || Data.TerminusDB.config()

    {:ok,
     assign(socket, config: config, errors: [], fields: blank_fields(), mode: :new, role_id: nil)}
  end

  @impl true
  def handle_params(%{"id" => role_id}, _uri, socket) do
    case RoleLoader.fetch(socket.assigns.config, role_id) do
      {:ok, fields} ->
        {:noreply, assign(socket, mode: :edit, role_id: role_id, fields: fields)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not load that role.")
         |> assign(mode: :edit, role_id: role_id, fields: blank_fields())}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, mode: :new, role_id: nil, fields: blank_fields())}
  end

  defp blank_fields do
    %{
      primary: "",
      description: "",
      context: "",
      synonyms: [],
      supporting: [],
      type_of: [],
      sibling: [],
      hard_negatives: [],
      easy_negatives: [],
      exclusions: [],
      locale: "",
      industry: "",
      confidence: "guess"
    }
  end

  @impl true
  def handle_event("add_item", %{"field" => field, "text" => text}, socket) do
    field = String.to_existing_atom(field)
    text = String.trim(text)

    fields =
      if text == "" do
        socket.assigns.fields
      else
        Map.update!(socket.assigns.fields, field, &(&1 ++ [text]))
      end

    {:noreply, assign(socket, fields: fields)}
  end

  def handle_event("remove_item", %{"field" => field, "index" => index}, socket) do
    field = String.to_existing_atom(field)
    index = String.to_integer(index)
    fields = Map.update!(socket.assigns.fields, field, &List.delete_at(&1, index))
    {:noreply, assign(socket, fields: fields)}
  end

  def handle_event("save", %{"role" => role_params}, socket) do
    fields = merge_scalar_fields(socket.assigns.fields, role_params)

    with true <- base_role_ok?(socket.assigns.config, fields),
         {:ok, built} <- RowBuilder.build(fields, base_role_exists?: true),
         parsed = to_parsed(built),
         {:ok, _summary} <- CsvImporter.import(socket.assigns.config, parsed) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved #{fields.primary}.")
       |> assign(errors: [], fields: fields)}
    else
      false ->
        {:noreply,
         assign(socket,
           errors: [
             "no base role found for #{inspect(fields.primary)} — the base (blank-context) role must exist first"
           ]
         )}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, errors: [message])}

      {:error, reason} ->
        {:noreply, assign(socket, errors: [inspect(reason)])}
    end
  end

  defp merge_scalar_fields(fields, params) do
    %{
      fields
      | primary: params["primary"] || "",
        description: params["description"] || "",
        context: params["context"] || "",
        locale: params["locale"] || "",
        industry: params["industry"] || "",
        confidence: params["confidence"] || ""
    }
  end

  defp base_role_ok?(_config, %{context: ""}), do: true

  defp base_role_ok?(config, %{primary: primary}) do
    case TerminusDB.Document.query(config, %{
           "@type" => "Role",
           "primary_name" => primary,
           "context" => ""
         }) do
      {:ok, [_ | _]} -> true
      {:ok, []} -> false
      {:error, _} -> false
    end
  end

  defp to_parsed(built) do
    %{
      roles: [built.role],
      skills: built.skills,
      pending_relations: built.relations,
      warnings: [],
      errors: []
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <.header>{if @mode == :new, do: "New role", else: "Edit role"}</.header>

      <div :if={@errors != []} class="alert alert-error">
        <p :for={error <- @errors}>{error}</p>
      </div>

      <form phx-submit="save">
        <input :if={@mode == :edit} type="hidden" name="role[primary]" value={@fields.primary} />
        <.input :if={@mode == :new} name="role[primary]" value={@fields.primary} label="Primary" />
        <.input
          name="role[description]"
          value={@fields.description}
          label="Description"
          type="textarea"
        />
        <.input name="role[context]" value={@fields.context} label="Context" />
        <.input name="role[locale]" value={@fields.locale} label="Locale" />
        <.input name="role[industry]" value={@fields.industry} label="Industry" />
        <.input
          name="role[confidence]"
          value={@fields.confidence}
          label="Confidence"
          type="select"
          options={["sure", "guess"]}
        />
        <.button>Save</.button>
      </form>

      <.list_section field={:synonyms} label="Synonyms" items={@fields.synonyms} />
      <.list_section field={:supporting} label="Supporting" items={@fields.supporting} />
      <.list_section field={:type_of} label="Type-of" items={@fields.type_of} />
      <.list_section field={:sibling} label="Sibling" items={@fields.sibling} />
      <.list_section field={:hard_negatives} label="Hard negatives" items={@fields.hard_negatives} />
      <.list_section field={:easy_negatives} label="Easy negatives" items={@fields.easy_negatives} />
      <.list_section field={:exclusions} label="Exclusions" items={@fields.exclusions} />
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :items, :list, required: true

  defp list_section(assigns) do
    ~H"""
    <fieldset class="mb-4" data-field={@field}>
      <legend class="font-semibold">{@label}</legend>
      <ul>
        <li :for={{item, index} <- Enum.with_index(@items)}>
          {item}
          <button
            type="button"
            phx-click="remove_item"
            phx-value-field={@field}
            phx-value-index={index}
          >
            Remove
          </button>
        </li>
      </ul>
      <form phx-submit="add_item" phx-value-field={@field}>
        <input type="text" name="text" placeholder={"Add " <> @label} />
        <button type="submit">Add</button>
      </form>
    </fieldset>
    """
  end
end
