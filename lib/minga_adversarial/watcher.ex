defmodule MingaAdversarial.Watcher do
  @moduledoc """
  Owns the adversarial analysis lifecycle.

  Subscribes to save/change/close events. Analysis runs on demand (the
  `adversarial-analyze` command) and, when the skepticism dial is `:on_save`
  or `:paranoid`, on save. Each analysis runs the model off-process and
  publishes findings through `Minga.Extension.Diagnostics`.

  Only the latest admitted analysis for a path can publish. Its reply
  consumes that request's ref, so late or duplicate replies are ignored.
  A user edit, explicit clear, or buffer close discards both the pending
  request and any published findings.

  The model, dispatch, and editor effects are injectable so the lifecycle
  can run without an editor process or network call.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferEvent
  alias Minga.Extension.AI
  alias Minga.Extension.Diagnostics
  alias MingaAdversarial.Findings
  alias MingaAdversarial.Prompt

  @extension_name :minga_adversarial
  @max_tokens 1024
  # Skip files larger than this; a background reviewer should not fan huge
  # files at the model. ponytail: flat byte cap, tune if it bites.
  @max_bytes 100_000
  @dial [:off, :manual, :on_save, :paranoid]

  @type skepticism :: :off | :manual | :on_save | :paranoid

  @typep editor :: %{
           subscribe: (Events.topic() -> :ok),
           file_path: (pid() -> String.t() | nil),
           configured_skepticism: (-> term()),
           publish: (atom(), String.t(), [Findings.finding()] -> :ok),
           clear: (atom(), String.t() -> :ok),
           clear_all: (atom() -> :ok)
         }

  @type state :: %{
          skepticism_override: skepticism() | nil,
          ai_fun: (list(), pos_integer() -> {:ok, String.t()} | {:error, term()}),
          dispatch: ((-> any()) -> any()),
          editor: editor(),
          pending: %{String.t() => reference()},
          published: MapSet.t(String.t())
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Analyzes `path` now. Returns `:off` when the dial is off, else `:ok`.

  Pass `content` to analyze in-memory buffer text (including unsaved edits);
  when `nil`, the file on disk is read instead.
  """
  @spec analyze(GenServer.server(), String.t(), String.t() | nil) :: :ok | :off
  def analyze(server \\ __MODULE__, path, content \\ nil) do
    GenServer.call(server, {:analyze, path, content})
  end

  @doc "Clears this extension's findings and invalidates pending analysis for `path`."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(server \\ __MODULE__, path) do
    GenServer.cast(server, {:clear, path})
  end

  @doc "Cycles the session skepticism dial and returns the new value."
  @spec cycle_skepticism(GenServer.server()) :: skepticism()
  def cycle_skepticism(server \\ __MODULE__) do
    GenServer.call(server, :cycle_skepticism)
  end

  # ── Server ───────────────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    editor = Keyword.get_lazy(opts, :editor, &editor_effects/0)
    editor.subscribe.(:buffer_saved)
    editor.subscribe.(:buffer_changed)
    editor.subscribe.(:buffer_closed)

    {:ok,
     %{
       skepticism_override: Keyword.get(opts, :skepticism),
       ai_fun: Keyword.get(opts, :ai_fun, &default_complete/2),
       dispatch: Keyword.get(opts, :dispatch, &default_dispatch/1),
       editor: editor,
       pending: %{},
       published: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:analyze, path, content}, _from, state) do
    case skepticism(state) do
      :off -> {:reply, :off, state}
      skep -> {:reply, :ok, request(state, path, content, skep)}
    end
  end

  def handle_call(:cycle_skepticism, _from, state) do
    next = next_dial(skepticism(state))
    {:reply, next, %{state | skepticism_override: next}}
  end

  @impl true
  def handle_cast({:clear, path}, state) do
    {:noreply, invalidate(state, path)}
  end

  @impl true
  def handle_info({:minga_event, :buffer_saved, %BufferEvent{path: path}}, state)
      when is_binary(path) do
    case skepticism(state) do
      # On save the buffer matches disk, so read from disk (content: nil).
      skep when skep in [:on_save, :paranoid] -> {:noreply, request(state, path, nil, skep)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:minga_event, :buffer_changed, %BufferChangedEvent{source: :user, buffer: buffer}},
        state
      ) do
    case safe_file_path(state.editor, buffer) do
      nil -> {:noreply, state}
      path -> {:noreply, invalidate(state, path)}
    end
  end

  def handle_info({:minga_event, :buffer_closed, %{path: path}}, state) when is_binary(path) do
    {:noreply, invalidate(state, path)}
  end

  def handle_info({:ai_result, path, ref, result}, state) do
    case state.pending do
      %{^path => ^ref} ->
        state = %{state | pending: Map.delete(state.pending, path)}
        {:noreply, deliver(state, path, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: state.editor.clear_all.(@extension_name)

  # ── Analysis ─────────────────────────────────────────────────────────────

  @spec request(state(), String.t(), String.t() | nil, skepticism()) :: state()
  defp request(state, path, given_content, skep) do
    case read_source(given_content, path) do
      {:ok, content} when byte_size(content) <= @max_bytes ->
        ref = make_ref()
        messages = Prompt.messages(path, content, skep)
        me = self()
        ai_fun = state.ai_fun

        state.dispatch.(fn ->
          send(me, {:ai_result, path, ref, ai_fun.(messages, @max_tokens)})
        end)

        %{state | pending: Map.put(state.pending, path, ref)}

      _ ->
        state
    end
  end

  # Prefer caller-provided (live buffer) content; fall back to disk.
  @spec read_source(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_source(content, _path) when is_binary(content), do: {:ok, content}
  defp read_source(_nil, path), do: File.read(path)

  @spec deliver(state(), String.t(), {:ok, String.t()} | {:error, term()}) :: state()
  defp deliver(state, path, {:ok, text}) do
    case Findings.parse(text) do
      [] -> clear_path(state, path)
      findings -> publish(state, path, findings)
    end
  end

  # Silent on failure: leave whatever is already shown, surface nothing.
  defp deliver(state, _path, {:error, _reason}), do: state

  @spec publish(state(), String.t(), [Findings.finding()]) :: state()
  defp publish(state, path, findings) do
    state.editor.publish.(@extension_name, path, findings)
    %{state | published: MapSet.put(state.published, path)}
  end

  @spec clear_path(state(), String.t()) :: state()
  defp clear_path(state, path) do
    if MapSet.member?(state.published, path) do
      state.editor.clear.(@extension_name, path)
      %{state | published: MapSet.delete(state.published, path)}
    else
      state
    end
  end

  @spec invalidate(state(), String.t()) :: state()
  defp invalidate(state, path) do
    state = %{state | pending: Map.delete(state.pending, path)}
    clear_path(state, path)
  end

  # ── Skepticism dial ──────────────────────────────────────────────────────

  @spec skepticism(state()) :: skepticism()
  defp skepticism(%{skepticism_override: override}) when override in @dial, do: override
  defp skepticism(state), do: configured_skepticism(state.editor)

  @spec configured_skepticism(editor()) :: skepticism()
  defp configured_skepticism(editor) do
    case editor.configured_skepticism.() do
      value when value in @dial -> value
      _ -> :manual
    end
  rescue
    _ -> :manual
  end

  @spec next_dial(skepticism()) :: skepticism()
  defp next_dial(current) do
    idx = Enum.find_index(@dial, &(&1 == current)) || 0
    Enum.at(@dial, rem(idx + 1, length(@dial)))
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec editor_effects() :: editor()
  defp editor_effects do
    %{
      subscribe: &Events.subscribe/1,
      file_path: &Buffer.file_path/1,
      configured_skepticism: fn -> Config.get_extension_option(@extension_name, :skepticism) end,
      publish: &Diagnostics.publish/3,
      clear: &Diagnostics.clear/2,
      clear_all: &Diagnostics.clear_all/1
    }
  end

  @spec safe_file_path(editor(), term()) :: String.t() | nil
  defp safe_file_path(editor, buffer) when is_pid(buffer) do
    editor.file_path.(buffer)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_file_path(_editor, _buffer), do: nil

  @spec default_complete([map()], pos_integer()) :: {:ok, String.t()} | {:error, term()}
  defp default_complete(messages, max_tokens) do
    AI.complete(messages, max_tokens: max_tokens)
  end

  @spec default_dispatch((-> any())) :: :ok
  defp default_dispatch(thunk) do
    Task.start(thunk)
    :ok
  end
end
