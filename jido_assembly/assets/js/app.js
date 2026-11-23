// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
// import {Socket} from "phoenix"
// import {LiveSocket} from "phoenix_live_view"
// import {hooks as colocatedHooks} from "phoenix-colocated/jido_assembly"
// import topbar from "../vendor/topbar"

// const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// const liveSocket = new LiveSocket("/live", Socket, {
//   longPollFallbackMs: 2500,
//   params: {_csrf_token: csrfToken},
//   hooks: {...colocatedHooks},
// })

// Show progress bar on live navigation and form submits
// topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
// window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
// window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
// liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
// window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
// if (process.env.NODE_ENV === "development") {
//   window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
//     // Enable server log streaming to client.
//     // Disable with reloader.disableServerLogs()
//     reloader.enableServerLogs()
// 
//     // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
//     //
//     //   * click with "c" key pressed to open at caller location
//     //   * click with "d" key pressed to open at function component definition location
//     let keyDown
//     window.addEventListener("keydown", e => keyDown = e.key)
//     window.addEventListener("keyup", _e => keyDown = null)
//     window.addEventListener("click", e => {
//       if(keyDown === "c"){
//         e.preventDefault()
//         e.stopImmediatePropagation()
//         reloader.openEditorAtCaller(e.target)
//       } else if(keyDown === "d"){
//         e.preventDefault()
//         e.stopImmediatePropagation()
//         reloader.openEditorAtDef(e.target)
//       }
//     }, true)
// 
//     window.liveReloader = reloader
//   })
// }


const composerFieldSelector = "[data-assembly-composer] input[type='text'], [data-assembly-composer] textarea"
const chatScrollSelector = "[data-assembly-chat-scroll]"
const threadScrollSelector = "[data-assembly-thread-scroll]"
const chatEndSelector = "[data-assembly-chat-end]"
const chatFocusSelector = "[data-assembly-focus-target='true']"
const mobileThreadSelector = '[role="dialog"][data-assembly-thread-root]'
const threadTriggerSelector = "[data-assembly-thread-trigger]"
const chatBottomThreshold = 160

const runAfterPaint = (callback) => {
  requestAnimationFrame(() => requestAnimationFrame(callback))
}

const chatBottomDistance = (scroller) => (
  scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight
)

const chatTailKey = (scroller) => {
  const messages = scroller.querySelectorAll("[data-assembly-room-message]")
  const lastMessage = messages[messages.length - 1]
  const lastMessageId = lastMessage?.getAttribute("data-assembly-message-id") || ""

  return `${scroller.dataset.assemblyRoomId}:${lastMessageId}`
}

const scrollChatToBottom = (scroller, { behavior = "smooth", force = false } = {}) => {
  if (!scroller) return

  const shouldScroll =
    force ||
    scroller.dataset.assemblyStickToBottom !== "false" ||
    chatBottomDistance(scroller) <= chatBottomThreshold

  if (!shouldScroll) return

  runAfterPaint(() => {
    if (scroller.querySelector(chatFocusSelector)) return

    const end = scroller.querySelector(chatEndSelector)

    if (end) {
      end.scrollIntoView({ block: "end", behavior })
    } else {
      scroller.scrollTo({ top: scroller.scrollHeight, behavior })
    }
  })
}

const focusChatTarget = (scroller) => {
  const target = [...scroller.querySelectorAll(chatFocusSelector)].find((message) => message.getClientRects().length)

  if (!target) {
    delete scroller.dataset.assemblyFocusedMessage
    return
  }

  const messageId = target.dataset.assemblyMessageId
  if (scroller.dataset.assemblyFocusedMessage === messageId) return
  scroller.dataset.assemblyFocusedMessage = messageId

  runAfterPaint(() => {
    if (!target.isConnected || !target.matches(chatFocusSelector)) return

    target.focus({ preventScroll: true })
    target.scrollIntoView({ block: "nearest" })
  })
}

const bindChatScroller = (scroller) => {
  if (scroller.dataset.assemblyChatScrollBound === "true") return

  scroller.dataset.assemblyChatScrollBound = "true"
  scroller.dataset.assemblyStickToBottom = "true"
  let tailKey = chatTailKey(scroller)

  scroller.addEventListener("scroll", () => {
    scroller.dataset.assemblyStickToBottom =
      chatBottomDistance(scroller) <= chatBottomThreshold ? "true" : "false"
  }, { passive: true })

  const observer = new MutationObserver(() => {
    focusChatTarget(scroller)
    const nextTailKey = chatTailKey(scroller)

    if (nextTailKey === tailKey) return

    tailKey = nextTailKey
    scrollChatToBottom(scroller, { force: true })
  })

  observer.observe(scroller, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-assembly-focus-target", "data-assembly-room-id"]
  })
  focusChatTarget(scroller)
  scrollChatToBottom(scroller, { behavior: "auto", force: true })
}

let activeThreadDialog = null
let threadOpener = null

document.addEventListener("click", (event) => {
  const opener = event.target.closest?.(threadTriggerSelector)
  if (opener) threadOpener = opener
}, true)

// A same-URL navigation can restore Hologram's saved Board or inbox view.
document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[data-assembly-release-target]")
  const dispatch = window.Hologram?.dispatchAction

  if (!link || link.href !== window.location.href || !dispatch ||
      event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

  const roomId = new URL(link.href).searchParams.get("room")
  if (!roomId) return

  event.preventDefault()
  dispatch("select_search_result", "page", {
    room_id: roomId,
    message_id: link.dataset.assemblyReleaseTarget
  })
})

const syncMobileThreadFocus = () => {
  const current = document.querySelector(mobileThreadSelector)
  const dialog = current?.getClientRects().length ? current : null
  const previous = activeThreadDialog
  activeThreadDialog = dialog

  if (dialog === previous) return

  if (dialog) {
    runAfterPaint(() => {
      if (activeThreadDialog === dialog && !dialog.querySelector(chatFocusSelector)) {
        dialog.querySelector("[data-assembly-thread-close]")?.focus({ preventScroll: true })
      }
    })
  } else if (previous && !previous.isConnected) {
    const rootId = previous.dataset.assemblyThreadRoot
    const opener = threadOpener
    threadOpener = null

    runAfterPaint(() => {
      if (activeThreadDialog) return

      const matches = (control) =>
        control?.dataset.assemblyThreadTrigger === rootId && control.getClientRects().length
      const trigger = matches(opener)
        ? opener
        : Array.from(document.querySelectorAll(threadTriggerSelector)).find(matches)

      trigger?.focus({ preventScroll: true })
    })
  }
}

const bindChatScrollers = () => {
  document.querySelectorAll(chatScrollSelector).forEach(bindChatScroller)
  document.querySelectorAll(`${mobileThreadSelector} ${threadScrollSelector}`).forEach(focusChatTarget)
  syncMobileThreadFocus()
}

let chatScrollObserverStarted = false

const startChatScrollObserver = () => {
  if (chatScrollObserverStarted) return

  const root = document.body || document.documentElement

  if (!root?.nodeType) return

  chatScrollObserverStarted = true

  new MutationObserver(bindChatScrollers).observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["data-assembly-focus-target"]
  })
}

const startChatScroll = () => {
  bindChatScrollers()
  startChatScrollObserver()
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", startChatScroll, { once: true })
} else {
  startChatScroll()
}

const pageWindow = document.defaultView || globalThis

pageWindow.AssemblyChat = {
  scrollToBottom: () => {
    document.querySelectorAll(chatScrollSelector).forEach((scroller) => {
      scrollChatToBottom(scroller, { force: true })
    })
  }
}

document.addEventListener("keydown", (event) => {
  const field = event.target.closest?.(composerFieldSelector)

  if (!field) return
  if (event.key !== "Enter") return
  if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey || event.isComposing) return

  event.preventDefault()
  field.form?.requestSubmit()
}, true)

// Handle flash close
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "")
  })
})
