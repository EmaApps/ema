---
order: 4
---
# CLI

Ema apps have a basic CLI argument structure that you can invoke in two possible ways:

1. `run` subcommand (or, no subcommand specified): Run the dev server.
2. `gen` subcommand: Generate the static site, instead of starting up the dev server

The subcommand is passed as the `Ema.CLI.Action` type to your `render` function. You can also use `runEmaWith` if you are manually handling the CLI arguments yourself.
