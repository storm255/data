# TerminusDB

This app uses [`terminusdb_client`](https://terminusdb-client.hexdocs.pm/readme.html)
to talk to a TerminusDB server for document storage. `TerminusDB.Config` is
plain immutable data (there's no connection process to supervise), so the
integration is a small config module plus an explicit provisioning step.

## Configuration

Connection settings are read from environment variables in
`config/runtime.exs`, which also loads a gitignored `.env` file (see
`.env.example`) if one is present — real environment variables always win
over `.env`, so this works the same in dev, test, and production.

| Variable                  | Purpose                              | Default   |
| -------------------------- | ------------------------------------- | --------- |
| `TERMINUSDB_URL`           | Server endpoint, e.g. `http://host:6363` | *(required)* |
| `TERMINUSDB_ADMIN_PASS`    | Admin password / API key             | *(required)* |
| `TERMINUSDB_ADMIN_USER`    | Basic auth username                  | `admin`   |
| `TERMINUSDB_ORGANIZATION`  | Organization that owns the database  | `admin`   |
| `TERMINUSDB_DATABASE`      | Database name                        | `data_dev` / `data_test` / `data` |

Copy `.env.example` to `.env` and fill in `TERMINUSDB_ADMIN_PASS` to get
started locally.

## Getting a config

`Data.TerminusDB.config/1` builds a `TerminusDB.Config` scoped to the
configured database:

```elixir
config = Data.TerminusDB.config()
```

Pass overrides (e.g. a different `:branch`, or an `:adapter` for stubbing in
tests) as a keyword list — they're merged over the application config before
`TerminusDB.Config.new/1` validates them.

## Provisioning: database + schema

Because a `Config` is just data, nothing provisions TerminusDB automatically
on application boot — a down TerminusDB shouldn't prevent Phoenix from
starting. Instead, run:

```
mix terminus.setup
```

This is idempotent and safe to run repeatedly (e.g. in a deploy step). It:

1. Creates the configured database if it doesn't already exist
   (`Data.TerminusDB.Setup.ensure_database!/1`).
2. Syncs the document schema classes returned by
   `Data.TerminusDB.Schema.classes/0` into the schema graph
   (`Data.TerminusDB.Setup.ensure_schema!/2`), inserting missing classes and
   replacing existing ones.

To add or change document types, edit the class list in
`Data.TerminusDB.Schema.classes/0`, then re-run `mix terminus.setup`.

## Working with documents

Once the database and schema exist, use `TerminusDB.Document` directly with a
scoped config:

```elixir
alias TerminusDB.Document

config = Data.TerminusDB.config()

{:ok, [id | _]} =
  Document.insert(config, %{"@type" => "Person", "name" => "Alice"},
    author: "admin",
    message: "add Alice"
  )

{:ok, docs} = Document.get(config, type: "Person", as_list: true)
{:ok, matches} = Document.query(config, %{"@type" => "Person", "name" => "Alice"})
{:ok, _} = Document.replace(config, Map.put(hd(docs), "name", "Alicia"), author: "admin", message: "rename")
{:ok, _} = Document.delete(config, id: id, author: "admin", message: "remove")
```

See the [terminusdb_client usage guide](https://terminusdb-client.hexdocs.pm/terminusdb_ex_livebook.html)
for more end-to-end examples (branches, streaming, schema frames).
