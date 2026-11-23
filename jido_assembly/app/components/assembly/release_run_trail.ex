defmodule Jido.Assembly.Components.Assembly.ReleaseRunTrail do
  use Hologram.Component

  prop :root, :map
  prop :replies, :list

  def template do
    ~HOLO"""
    {%if release_request?(@root)}
      <details class="mt-3 rounded-md border border-[var(--assembly-chat-line)] p-3 text-xs" aria-label="Run trail">
        <summary class="cursor-pointer font-semibold">Run trail</summary>
        <ol class="mt-2 space-y-2">
          <li>
            <a class="font-semibold underline" href={@root.permalink}>Request</a>
            <code class="mt-0.5 block break-all text-[var(--assembly-chat-muted)]">{@root.id}</code>
          </li>
          {%for run <- run_rows(@root, @replies)}
            <li data-assembly-run-id={run.id} data-assembly-parent-run-id={run.parent_run_id}>
              <span class="font-semibold">{run.label}</span>
              <span>{run.status}</span>
              <code class="mt-0.5 block break-all text-[var(--assembly-chat-muted)]">{run.id}</code>
              {%if run.parent_run_id}
                <p class="mt-0.5 break-all text-[var(--assembly-chat-muted)]">Parent run <code>{run.parent_run_id}</code></p>
              {/if}
              {%if run.result}
                <a class="mt-0.5 inline-block underline" href={run.result.permalink}>Run result</a>
              {/if}
            </li>
          {/for}
          {%for step <- release_steps(@root.id, @replies)}
            <li>
              <a class="font-semibold underline" href={step.href}>{step.label}</a>
              <code class="mt-0.5 block break-all text-[var(--assembly-chat-muted)]">{step.id}</code>
              {%if step.destination}
                <a class="mt-0.5 inline-block underline" href={step.destination}>Published message</a>
              {/if}
            </li>
          {/for}
        </ol>
      </details>
    {/if}
    """
  end

  defp release_request?(%{metadata: %{"assembly_release_note" => %{"type" => "request"}}}),
    do: true

  defp release_request?(_root), do: false

  defp run_rows(root, replies) do
    Enum.map(Map.get(root, :agent_runs, []), fn run ->
      result = Enum.find(replies, fn reply -> reply.id == run.reply_id end)
      Map.put(run, :result, result)
    end)
  end

  defp release_steps(root, replies) do
    Enum.flat_map(replies, fn reply -> release_step(reply, root) end)
  end

  defp release_step(
         %{metadata: %{"assembly_release_note" => %{"run_id" => root} = event}} = reply,
         root
       ) do
    case step_label(event) do
      nil ->
        []

      label ->
        [
          %{
            label: label,
            id: reply.id,
            href: reply.permalink,
            destination: Map.get(reply, :release_publication_receipt)
          }
        ]
    end
  end

  defp release_step(_reply, _root), do: []

  defp step_label(%{"type" => "decision"}), do: "Decision"
  defp step_label(%{"type" => "decision_answer"}), do: "Decision answer"

  defp step_label(%{"type" => type, "version" => version})
       when type in ["draft", "revision"] and is_integer(version),
       do: "Release note v" <> Integer.to_string(version)

  defp step_label(%{"type" => "review"}), do: "Version review"
  defp step_label(%{"type" => "publish_proposal"}), do: "Publish proposal"
  defp step_label(%{"type" => "publish_approval"}), do: "Publish approval"
  defp step_label(%{"type" => "publish_receipt"}), do: "Delivery receipt"
  defp step_label(%{"type" => "publish_uncertain"}), do: "Uncertain delivery"
  defp step_label(_event), do: nil
end
