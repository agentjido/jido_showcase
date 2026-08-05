defmodule Jido.Assembly.Components.Assembly.DeveloperInspectorPanel do
  use Hologram.Component

  prop :active_room_name, :string
  prop :active_room_prefix, :string
  prop :connector_snapshot, :map
  prop :developer_capabilities, :list
  prop :developer_contract, :list
  prop :developer_message_inspector, :map
  prop :developer_room_metrics, :list
  prop :developer_stack, :list
  prop :last_event, :map
  prop :thread_open, :boolean

  def template do
    ~HOLO"""
    {%if @thread_open == false}
      <aside class="hidden min-h-0 flex-col border-l border-[var(--assembly-line)] bg-[var(--assembly-panel-muted)] xl:flex">
        <header class="border-b border-[var(--assembly-line)] px-5 py-4">
          <h2 class="text-sm font-bold text-[var(--assembly-ink)]">Developer inspector</h2>
          <p class="mt-1 text-sm text-[var(--assembly-muted)]">{@active_room_prefix} {@active_room_name}</p>
        </header>
        <div class="space-y-5 overflow-y-auto p-5">
          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Conversation state</h3>
            <div class="space-y-2">
              {%for metric <- @developer_room_metrics}
                <div class="flex items-center justify-between rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] px-3 py-2 text-sm">
                  <span>{metric.label}</span>
                  <span class="font-semibold text-stone-700">{metric.value}</span>
                </div>
              {/for}
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Last event</h3>
            <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] p-3 text-sm">
              <div class="flex items-center justify-between gap-3">
                <span class="font-bold text-stone-800">{@last_event.title}</span>
                <span class="rounded-md bg-emerald-100 px-2 py-0.5 text-xs font-semibold text-emerald-800">{@last_event.layer}</span>
              </div>
              <p class="mt-2 leading-6 text-stone-700">{@last_event.detail}</p>
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Message inspector</h3>
            <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] p-3 text-sm">
              <p class="font-bold text-stone-800">{@developer_message_inspector.title}</p>
              <div class="mt-3 space-y-3 text-xs">
                <div>
                  <p class="font-semibold uppercase text-[var(--assembly-muted)]">Provider payload</p>
                  <pre class="mt-1 max-h-28 overflow-auto rounded bg-[var(--assembly-panel-muted)] p-2 leading-relaxed text-stone-700">{@developer_message_inspector.provider_payload_text}</pre>
                </div>
                <div>
                  <p class="font-semibold uppercase text-[var(--assembly-muted)]">Normalized message</p>
                  <pre class="mt-1 max-h-28 overflow-auto rounded bg-[var(--assembly-panel-muted)] p-2 leading-relaxed text-stone-700">{@developer_message_inspector.normalized_message_text}</pre>
                </div>
                <div>
                  <p class="font-semibold uppercase text-[var(--assembly-muted)]">Persisted record</p>
                  <pre class="mt-1 max-h-28 overflow-auto rounded bg-[var(--assembly-panel-muted)] p-2 leading-relaxed text-stone-700">{@developer_message_inspector.persisted_record_text}</pre>
                </div>
                <div>
                  <p class="font-semibold uppercase text-[var(--assembly-muted)]">Delivery</p>
                  <pre class="mt-1 max-h-28 overflow-auto rounded bg-[var(--assembly-panel-muted)] p-2 leading-relaxed text-stone-700">{@developer_message_inspector.delivery_text}</pre>
                </div>
              </div>
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Connector control plane</h3>
            <div class="space-y-2">
              {%for connector <- @connector_snapshot.connectors}
                <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] px-3 py-2 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-semibold text-stone-800">{connector.name}</span>
                    <span class="rounded bg-[var(--assembly-panel-muted)] px-2 py-0.5 text-xs font-semibold text-[var(--assembly-muted)]">{connector.status}</span>
                  </div>
                  <p class="mt-1 text-xs leading-5 text-[var(--assembly-muted)]">{connector.adapter_module}</p>
                  <div class="mt-2 grid gap-1 text-xs text-stone-700">
                    <div class="flex justify-between gap-2">
                      <span>Bridge</span>
                      <span class="font-semibold">{connector.bridge_id}</span>
                    </div>
                    <div class="flex justify-between gap-2">
                      <span>Target</span>
                      <span class="truncate font-semibold">{connector.target_label}</span>
                    </div>
                    <div class="flex justify-between gap-2">
                      <span>Listeners</span>
                      <span class="font-semibold">{connector.listener_count_label}</span>
                    </div>
                  </div>
                </div>
              {/for}
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Jido Chat contract</h3>
            <div class="space-y-2">
              {%for item <- @developer_contract}
                <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] px-3 py-2 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span>{item.label}</span>
                    <span class="font-semibold text-stone-700">{item.value}</span>
                  </div>
                  <p class="mt-1 text-xs leading-5 text-[var(--assembly-muted)]">{item.detail}</p>
                </div>
              {/for}
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Stack path</h3>
            <div class="space-y-2">
              {%for layer <- @developer_stack}
                <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] p-3">
                  <div class="flex items-center justify-between gap-3">
                    <h4 class="text-sm font-bold text-[var(--assembly-ink)]">{layer.name}</h4>
                    <span class="rounded-md bg-[var(--assembly-panel-muted)] px-2 py-0.5 text-xs font-semibold text-[var(--assembly-muted)]">{layer.badge}</span>
                  </div>
                  <p class="mt-2 text-xs leading-5 text-stone-700">{layer.role}</p>
                </div>
              {/for}
            </div>
          </section>

          <section>
            <h3 class="mb-2 text-xs font-semibold text-[var(--assembly-muted)]">Demo scope</h3>
            <div class="space-y-2">
              {%for capability <- @developer_capabilities}
                <div class="rounded-md border border-[var(--assembly-line)] bg-[var(--assembly-panel)] px-3 py-2 text-sm">
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-semibold text-stone-800">{capability.feature}</span>
                    <span class="text-xs font-semibold {if capability.status == "implemented" do "text-emerald-700" else "text-stone-500" end}">{capability.status}</span>
                  </div>
                  <p class="mt-1 text-xs leading-5 text-[var(--assembly-muted)]">{capability.detail}</p>
                </div>
              {/for}
            </div>
          </section>
        </div>
      </aside>
    {/if}
    """
  end
end
