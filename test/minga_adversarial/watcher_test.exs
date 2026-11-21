defmodule MingaAdversarial.WatcherTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Events.BufferChangedEvent
  alias Minga.Events.BufferEvent
  alias MingaAdversarial.Watcher

  @ext :minga_adversarial

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "buffer.ex")
    File.write!(path, "defmodule Foo do\n  def bar(list), do: hd(list)\nend\n")
    %{path: path}
  end

  defp start_watcher(id, path, opts \\ []) do
    owner = self()
    {skepticism, opts} = Keyword.pop(opts, :configured_skepticism)

    editor = %{
      subscribe: fn topic -> report(owner, {:subscribed, topic}) end,
      file_path: fn ^owner -> path end,
      configured_skepticism: fn -> skepticism end,
      publish: fn ext, path, findings -> report(owner, {:publish, ext, path, findings}) end,
      clear: fn ext, path -> report(owner, {:clear, ext, path}) end,
      clear_all: fn ext -> report(owner, {:clear_all, ext}) end
    }

    opts = Keyword.merge(opts, name: nil, editor: editor)
    start_supervised!(%{id: id, start: {Watcher, :start_link, [opts]}})
  end

  defp report(owner, message) do
    send(owner, message)
    :ok
  end

  defp one_finding, do: ~s([{"line": 2, "concern": "hd/1 assumes list is non-empty"}])

  defp start_capturing_watcher(id, path, opts \\ []) do
    test_pid = self()

    opts =
      Keyword.merge(opts,
        dispatch: fn thunk -> send(test_pid, {:dispatch, thunk}) end,
        ai_fun: fn _messages, _max ->
          assert_receive {:model_result, result}
          result
        end
      )

    start_watcher(id, path, opts)
  end

  defp capture_analysis(server, path) do
    assert :ok = Watcher.analyze(server, path)
    assert_receive {:dispatch, thunk}
    thunk
  end

  defp deliver_reply(server, thunk, result \\ {:ok, one_finding()}) do
    send(self(), {:model_result, result})
    thunk.()
    flush(server)
  end

  # A mailbox barrier for events sent by the test process.
  defp flush(server), do: :sys.get_state(server)

  defp assert_default_finding(path) do
    assert_received {:publish, @ext, ^path,
                     [%{line: 1, concern: "hd/1 assumes list is non-empty"}]}
  end

  test "manual analyze emits a zero-based advisory finding", %{path: path} do
    server =
      start_watcher(:manual_publish, path, ai_fun: fn _messages, _max -> {:ok, one_finding()} end)

    assert_receive {:subscribed, :buffer_saved}
    assert_receive {:subscribed, :buffer_changed}
    assert_receive {:subscribed, :buffer_closed}

    assert :ok = Watcher.analyze(server, path)

    assert_receive {:publish, @ext, ^path,
                    [%{line: 1, concern: "hd/1 assumes list is non-empty"}]},
                   2_000

    stop_supervised!(:manual_publish)
    assert_receive {:clear_all, @ext}
  end

  test "analyze uses provided live content instead of the file on disk", %{path: path} do
    File.write!(path, "on_disk_only\n")
    test_pid = self()

    server =
      start_watcher(:live_content, path,
        ai_fun: fn messages, _max ->
          send(test_pid, {:msgs, messages})
          {:error, :unavailable}
        end
      )

    assert :ok = Watcher.analyze(server, path, "live_buffer_text\n")

    assert_receive {:msgs, messages}, 2_000
    user = Enum.find(messages, &(&1.role == "user")).content
    assert user =~ "live_buffer_text"
    refute user =~ "on_disk_only"
  end

  test "dial off makes analyze a no-op", %{path: path} do
    server = start_capturing_watcher(:off, path, configured_skepticism: :off)

    assert :off = Watcher.analyze(server, path)
    refute_received {:dispatch, _thunk}
    refute_received {:publish, @ext, ^path, _}
  end

  test "manual does not analyze on save; on_save and paranoid do", %{path: path} do
    event = {:minga_event, :buffer_saved, %BufferEvent{buffer: self(), path: path}}
    manual = start_capturing_watcher(:save_manual, path)
    send(manual, event)
    flush(manual)
    refute_received {:dispatch, _}

    for mode <- [:on_save, :paranoid] do
      server = start_capturing_watcher(mode, path, configured_skepticism: mode)
      send(server, event)
      assert_receive {:dispatch, thunk}
      deliver_reply(server, thunk)
      assert_default_finding(path)
    end
  end

  test "an older reply does not publish or displace the newer request", %{path: path} do
    server = start_capturing_watcher(:stale, path)
    older = capture_analysis(server, path)
    newer = capture_analysis(server, path)

    deliver_reply(server, older)
    refute_received {:publish, @ext, ^path, _}

    deliver_reply(server, newer, {:ok, ~s([{"line": 1, "concern": "fresh"}])})
    assert_received {:publish, @ext, ^path, [%{line: 0, concern: "fresh"}]}

    deliver_reply(server, newer, {:ok, "[]"})
    refute_received {:clear, @ext, ^path}
  end

  test "failed source reads and oversized requests leave the admitted analysis pending", %{
    path: path
  } do
    server = start_capturing_watcher(:rejected, path)
    pending = capture_analysis(server, path)

    File.rm!(path)
    assert :ok = Watcher.analyze(server, path)
    assert :ok = Watcher.analyze(server, path, String.duplicate("x", 100_001))
    refute_received {:dispatch, _thunk}

    deliver_reply(server, pending)
    assert_default_finding(path)
  end

  test "a model error retains findings but consumes its request; an empty success clears", %{
    path: path
  } do
    server = start_capturing_watcher(:terminal, path)
    deliver_reply(server, capture_analysis(server, path))
    assert_default_finding(path)

    failed = capture_analysis(server, path)
    deliver_reply(server, failed, {:error, :unavailable})
    refute_received {:clear, @ext, ^path}
    refute_received {:publish, @ext, ^path, _}

    deliver_reply(server, failed, {:ok, "[]"})
    refute_received {:clear, @ext, ^path}

    deliver_reply(server, capture_analysis(server, path), {:ok, "[]"})
    assert_received {:clear, @ext, ^path}
  end

  test "explicit clear drops findings and any pending reply", %{path: path} do
    server = start_capturing_watcher(:clear, path)
    deliver_reply(server, capture_analysis(server, path))
    assert_default_finding(path)
    pending = capture_analysis(server, path)

    assert :ok = Watcher.clear(server, path)
    flush(server)
    assert_received {:clear, @ext, ^path}

    deliver_reply(server, pending)
    refute_received {:publish, @ext, ^path, _}
  end

  test "a user edit drops findings and any pending reply", %{path: path} do
    server = start_capturing_watcher(:edit, path)
    deliver_reply(server, capture_analysis(server, path))
    assert_default_finding(path)
    pending = capture_analysis(server, path)

    event = %BufferChangedEvent{buffer: self(), source: :user}
    send(server, {:minga_event, :buffer_changed, event})

    flush(server)
    assert_received {:clear, @ext, ^path}

    deliver_reply(server, pending)
    refute_received {:publish, @ext, ^path, _}
  end

  test "close drops findings and pending replies, even after reopening the same path", %{
    path: path
  } do
    server = start_capturing_watcher(:reopen, path)
    deliver_reply(server, capture_analysis(server, path))
    assert_default_finding(path)
    before_close = capture_analysis(server, path)

    send(server, {:minga_event, :buffer_closed, %{buffer: self(), path: path}})
    flush(server)
    assert_received {:clear, @ext, ^path}

    deliver_reply(server, before_close)
    refute_received {:publish, @ext, ^path, _}

    after_reopen = capture_analysis(server, path)
    deliver_reply(server, before_close)
    refute_received {:publish, @ext, ^path, _}

    deliver_reply(server, after_reopen)
    assert_default_finding(path)
  end

  test "cycle_skepticism advances through the dial", %{path: path} do
    server = start_watcher(:cycle, path)

    assert Watcher.cycle_skepticism(server) == :on_save
    assert Watcher.cycle_skepticism(server) == :paranoid
    assert Watcher.cycle_skepticism(server) == :off
    assert Watcher.cycle_skepticism(server) == :manual
  end
end
