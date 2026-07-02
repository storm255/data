defmodule Data.TerminusDB.Schema do
  @moduledoc """
  The document schema (TerminusDB `Class` definitions) for this application.
  Synced into the database by `mix terminus.setup` via `Data.TerminusDB.Setup.ensure_schema!/2`.

  Currently the skill taxonomy schema (see `design/SKILLS_TAXONOMY.md` §3):
  `Role`, `Skill`, and `RoleRelation` as top-level document classes, plus
  `Synonym` and `Keyword` as embedded subdocuments of `Role`.

  `relation_type`, `confidence`, and other string-valued fields are plain
  `xsd:string` rather than a TerminusDB `Enum` class — the small, fixed set
  of allowed values (`"supporting"`, `"sure"`/`"guess"`, etc.) is validated
  in Elixir (the CSV importer and LiveView form), not enforced by the
  TerminusDB schema itself, to keep the schema itself small and this
  module easy to read as a single source of truth for field shapes.
  """

  @doc "Returns the list of `Class` document maps that make up the schema."
  @spec classes() :: [map()]
  def classes do
    [synonym(), keyword(), role(), skill(), role_relation()]
  end

  # Embedded subdocument of Role.synonyms — an alternate name for a role in
  # a given locale. Lexical-keyed on {term, locale} so re-asserting the same
  # synonym is idempotent rather than creating a duplicate subdocument.
  defp synonym do
    %{
      "@type" => "Class",
      "@id" => "Synonym",
      "@subdocument" => [],
      "@key" => %{"@type" => "Lexical", "@fields" => ["term", "locale"]},
      "term" => "xsd:string",
      "locale" => "xsd:string",
      "confidence" => %{"@type" => "Optional", "@class" => "xsd:string"}
    }
  end

  # Embedded subdocument of Role.keywords — the "App Keywords / Job
  # Phrases" section (design doc §4): free-text search/discovery phrases,
  # not relationship data. `category` is one of "worker_profile" |
  # "employer_job_post" | "local_language" | "trend_signal", validated in
  # Elixir like other small string enums (see moduledoc). Lexical-keyed on
  # {category, phrase} for the same re-assert idempotency as Synonym.
  defp keyword do
    %{
      "@type" => "Class",
      "@id" => "Keyword",
      "@subdocument" => [],
      "@key" => %{"@type" => "Lexical", "@fields" => ["category", "phrase"]},
      "category" => "xsd:string",
      "phrase" => "xsd:string"
    }
  end

  # A job title. `context` disambiguates venue-tier/setting variants of the
  # same `primary_name` (e.g. a fine-dining Waitstaff vs. the base role) —
  # blank ("") for the general/base row. Part of the Lexical key so a
  # variant is a distinct Role document, not an overwrite of the base one.
  #
  # `status` is "differentiated" (came from an actual contributor entry)
  # or "stub" (auto-created as a relation target that doesn't have its
  # own entry yet — see design doc §2, "Stub roles").
  defp role do
    %{
      "@type" => "Class",
      "@id" => "Role",
      "@key" => %{"@type" => "Lexical", "@fields" => ["primary_name", "context"]},
      "primary_name" => "xsd:string",
      "context" => "xsd:string",
      "locale" => "xsd:string",
      "industry" => "xsd:string",
      "description" => %{"@type" => "Optional", "@class" => "xsd:string"},
      "status" => "xsd:string",
      "synonyms" => %{"@type" => "Set", "@class" => "Synonym"},
      "keywords" => %{"@type" => "Set", "@class" => "Keyword"}
    }
  end

  # A capability, cert, or ability — not itself a job.
  defp skill do
    %{
      "@type" => "Class",
      "@id" => "Skill",
      "@key" => %{"@type" => "Lexical", "@fields" => ["name"]},
      "name" => "xsd:string"
    }
  end

  # A typed edge between two Role/Skill documents (referenced by @id string
  # in `from`/`to` — see moduledoc). Lexical-keyed on {from, to,
  # relation_type} so re-importing the same relationship updates it in
  # place instead of creating a duplicate. `weight` defaults to 1.0 at the
  # application layer (Data.Reasoning.Catalogs.SkillTaxonomy) — it's not
  # contributor-set, see design doc §2.
  defp role_relation do
    %{
      "@type" => "Class",
      "@id" => "RoleRelation",
      "@key" => %{"@type" => "Lexical", "@fields" => ["from", "to", "relation_type"]},
      "from" => "xsd:string",
      "to" => "xsd:string",
      "relation_type" => "xsd:string",
      "confidence" => "xsd:string",
      "weight" => "xsd:decimal",
      "relationship_detail" => %{"@type" => "Optional", "@class" => "xsd:string"},
      "locale" => %{"@type" => "Optional", "@class" => "xsd:string"},
      "industry" => %{"@type" => "Optional", "@class" => "xsd:string"},
      "notes" => %{"@type" => "Optional", "@class" => "xsd:string"}
    }
  end
end
