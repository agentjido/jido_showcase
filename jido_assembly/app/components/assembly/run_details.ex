defmodule Jido.Assembly.Components.Assembly.RunDetails do
  use Hologram.Component

  alias Jido.Assembly.Components.Assembly.ReleaseRunTrail

  prop :room_name, :string
  prop :room_prefix, :string
  prop :root, :any
  prop :replies, :list

  def template do
    ~HOLO"""
    <aside class="assembly-run-details" id="assembly-run-details" tabindex="-1" aria-label="Run details">
      <section>
        <h2>Agent run</h2>
        <div class="assembly-agent-summary">
          <span class="assembly-avatar" data-role="Agent" aria-hidden="true">TR</span>
          <div><strong>Triage</strong><small>Agent for {@room_prefix}{@room_name}</small></div>
        </div>
        <span class="assembly-status" data-stage={stage(@root, @replies)}>{status(@root, @replies)}</span>
        <p class="assembly-run-note">{guidance(@root, @replies)}</p>
        {%if release_room?(@room_name)}
          <ol class="assembly-steps">
            {%for {step, label} <- steps()}
              <li aria-current={if step == stage(@root, @replies) do "step" else "false" end}>{label}</li>
            {/for}
          </ol>
        {/if}
        {%if @root}
          <a class="assembly-text-link mt-2 inline-block" href={@root.permalink}>Open triggering message</a>
          <ReleaseRunTrail root={@root} replies={@replies} />
        {/if}
      </section>
      {%if release_room?(@room_name)}
        <section>
          <h2>Triage’s scope</h2>
          <p><strong>Reads</strong> evidence from the release conversation.</p>
          <p><strong>Posts</strong> decisions and versioned notes in the request thread.</p>
          <p><strong>Waits</strong> for review and for approval before publishing.</p>
        </section>
        <section>
          <h2>Sources</h2>
          {%for source <- sources(@replies)}
            <details class="assembly-source">
              <summary>{source.title}</summary>
              <p>{source.evidence}</p>
              <a class="assembly-text-link" href={source.href}>Open source message</a>
            </details>
          {/for}
          {%if sources(@replies) == []}<p>Citations appear here when Triage posts a draft.</p>{/if}
        </section>
      {/if}
    </aside>
    """
  end

  defp release_room?(name), do: name == "jido-chat-release"

  defp steps do
    [
      {"starting", "Triage reads the conversation"},
      {"decision", "Requester answers a decision"},
      {"drafting", "Triage prepares a release note"},
      {"review", "Assigned teammate reviews"},
      {"reviewed", "Review complete"}
    ]
  end

  defp stage(nil, _replies), do: "idle"

  defp stage(root, replies) do
    case root.metadata["assembly_release_note"] do
      %{"type" => "request"} -> latest_release_stage(replies)
      _other -> "thread"
    end
  end

  defp latest_release_stage(replies) do
    replies
    |> Enum.reverse()
    |> Enum.find_value("starting", fn reply ->
      case reply.metadata["assembly_release_note"] do
        %{"type" => "decision"} -> "decision"
        %{"type" => "decision_answer"} -> "drafting"
        %{"type" => type} when type in ["draft", "revision"] -> "review"
        %{"type" => "review"} -> "reviewed"
        %{"type" => "cancelled"} -> "cancelled"
        _other -> nil
      end
    end)
  end

  defp status(root, replies) do
    case stage(root, replies) do
      "idle" -> "No thread selected"
      "thread" -> "Thread open"
      "starting" -> "Preparing decision"
      "decision" -> "Decision needed"
      "drafting" -> "Preparing draft"
      "review" -> "Ready for review"
      "reviewed" -> "Reviewed"
      "cancelled" -> "Cancelled"
    end
  end

  defp guidance(root, replies) do
    case stage(root, replies) do
      "idle" -> "Mention @triage in the conversation or open a thread to see its activity."
      "thread" -> "Run activity and replies link back to the message that opened this thread."
      "starting" -> "Triage is preparing a decision for the requester."
      "decision" -> "Answer the decision in the thread to continue."
      "drafting" -> "Triage uses the decision to prepare a release note."
      "review" -> "Open the sources and review the current version in the thread."
      "reviewed" -> "The current version has been reviewed."
      "cancelled" -> "The request and its history are still in the conversation."
    end
  end

  defp sources(replies) do
    replies
    |> Enum.reverse()
    |> Enum.find_value([], fn reply ->
      case Map.get(reply, :release_artifact) do
        %{sources: sources} -> sources
        _other -> nil
      end
    end)
  end
end
