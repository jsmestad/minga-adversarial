# Minga Adversarial

Challenge the assumptions in the current file and see the model’s findings as advisory `?` signs in Minga’s gutter. Findings appear in hover and diagnostic navigation, and clear as you edit.

## Install

Use a Minga build that supports the public extension notice and option APIs. Add this line to `~/.config/minga/config.exs` below your existing `use Minga.Config`, then restart Minga and confirm the install:

```elixir
extension :minga_adversarial, git: "https://github.com/jsmestad/minga-adverserial"
```

Press `SPC a A` or run `M-x adversarial-analyze` to review the current file. A review sends the current buffer, including unsaved edits, to your configured Minga model. Run `M-x adversarial-clear` to dismiss the findings.

The default skepticism level, `:manual`, only runs a review when you ask. Choose another default in the same extension declaration:

```elixir
extension :minga_adversarial, git: "https://github.com/jsmestad/minga-adverserial", skepticism: :on_save
```

- `:off` disables analysis, including the manual command.
- `:on_save` also reviews files when you save them.
- `:paranoid` reviews on save with a more skeptical prompt.

`M-x adversarial-cycle-skepticism` changes the level for the current session.

## Develop

Use the Elixir and OTP versions in `.tool-versions`. You do not need an editor checkout to run the standalone checks. The SDK dependency must include `MingaEditor.Extension.EditorAPI.notice/2` and `Minga.Config.get_extension_option/2`.

```sh
export MIX_ENV=test
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo
mix test --warnings-as-errors
```
