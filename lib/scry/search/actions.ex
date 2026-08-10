defmodule Scry.Search.Actions do
  @moduledoc """
  Turns the *merged* (core + this package's own fragment) parse tree
  into a `%Scry.Core.Query{}`, the exact same target `Scry.Core.Actions`
  produces alone -- this module owns exactly the one rule `priv/
  grammar.aether` adds (`comparison_ep1e`, lang_spec.md §8.5's `<field>
  SEARCH <string>`) and delegates every other rule/token straight
  through to `Scry.Core.Actions`'s own functions, the same delegation-
  not-composition shape every other kind package's own identical
  module already established (see any one of their own moduledocs for
  the full "why delegation, and why naive delegation is subtly wrong"
  reasoning -- identical here, not re-derived).

  **The one genuine difference from every EP1(b)/(c)/(d) kind package
  built so far**: `body_item`'s own handler, in `Scry.Core.Actions`,
  wraps whatever a `body_item_ep1` handler returns as `{:variant,
  value}` -- but `comparison` (the host production `comparison_ep1e`
  extends) has no equivalent wrapping clause for it at all (confirmed
  directly, not assumed: `Scry.Core.Actions.handle_rule/3` has exactly
  four `:comparison` clauses, none matching a bare `%{comparison_ep1e:
  _}` single-key capture, so reaching core's own handler with that
  shape would raise `FunctionClauseError`). This module's own
  `comparison_ep1e` handler therefore does the `{:variant, ...}}`
  wrapping itself, directly -- `predicate()`'s own new leaf shape
  (`Scry.Core.Query`'s own moduledoc has the full reasoning), not
  something core does on this package's behalf. `Scry.Search.Executor`
  is what actually interprets `{:variant, {:search, left, needle}}`;
  `Scry.Core.Executor`/`Scry.Core.QueryOps` have no notion of it and
  hard-error clearly if one ever reaches them unresolved.
  """

  @behaviour Ichor.Actions

  alias Ichor.Capture

  @impl true
  def handle_token(name, text, ctx) do
    Scry.Core.Actions.handle_token(name, text, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_token) do
        {:ok, text, ctx}
      else
        reraise e, __STACKTRACE__
      end
  end

  # lang_spec.md §8.5: `<field> SEARCH <string>`. `left` is core's own
  # `predicate_lhs` (`call_with_path | call | path`), reused verbatim;
  # `right` is `right_cap.eval.(ctx)` delegating to `Scry.Core.Actions.
  # handle_token(:STRING, ...)` for the actual unescape/decode -- an
  # ordinary already-decoded Elixir string by the time this handler
  # sees it, never the raw quoted token text.
  @impl true
  def handle_rule(:comparison_ep1e, %{left: left_cap, right: right_cap}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, right, ctx} <- right_cap.eval.(ctx) do
      {:ok, {:variant, {:search, left, right}}, ctx}
    end
  end

  def handle_rule(rule, captures, ctx) do
    Scry.Core.Actions.handle_rule(rule, captures, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_rule) do
        default_handle_rule(rule, captures, ctx)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp delegate_had_no_clause?(%FunctionClauseError{} = e, expected_function) do
    e.module == Scry.Core.Actions and e.function == expected_function and e.arity == 3
  end

  # `default_handle_rule/3`/`build_node/3`: a direct port of
  # `Ichor.Actions`'s own identically-named private functions
  # (`ichor_runtime`, `lib/ichor/actions.ex`) -- see this module's own
  # moduledoc, and every other kind package's own identical functions,
  # for why a port, not a call, is necessary here.
  defp default_handle_rule(rule_name, captures, ctx) when map_size(captures) == 1 do
    case Map.to_list(captures) do
      [{_name, %Capture{} = cap}] -> cap.eval.(ctx)
      [{_name, list}] when is_list(list) -> build_node(rule_name, captures, ctx)
    end
  end

  defp default_handle_rule(rule_name, captures, ctx), do: build_node(rule_name, captures, ctx)

  defp build_node(rule_name, captures, ctx) do
    with {:ok, resolved, ctx} <- Ichor.Actions.eval_all(captures, ctx) do
      {:ok, %Ichor.Node{rule: rule_name, captures: resolved, span: nil}, ctx}
    end
  end
end
